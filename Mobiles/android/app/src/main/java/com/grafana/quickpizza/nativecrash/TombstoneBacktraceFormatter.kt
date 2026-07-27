package com.grafana.quickpizza.nativecrash

import java.util.Locale

/**
 * Converts Android tombstone data into text backtrace format for NDK retrace.
 */
internal object TombstoneBacktraceFormatter {

    private val nativeFrameLine = Regex("""^\s*#\d+\s+pc\s+(?:0x)?[0-9a-fA-F]+\s+\S+""")

    fun looksLikeNativeBacktrace(text: String): Boolean {
        if (text.isBlank()) {
            return false
        }
        return text.lineSequence().any { nativeFrameLine.containsMatchIn(it) }
    }

    fun looksLikeTextTombstone(text: String): Boolean {
        if (text.isBlank()) {
            return false
        }
        if (looksLikeNativeBacktrace(text)) {
            return true
        }
        return text.contains("*** *** ***") || text.contains("backtrace:")
    }

    /** Keeps tombstone metadata + backtrace frames, dropping memory maps and other noise. */
    fun extractBacktraceSection(fullTrace: String): String {
        val trimmed = fullTrace.trim()
        if (trimmed.isEmpty()) {
            return ""
        }
        if (!trimmed.contains("backtrace:", ignoreCase = true)) {
            return trimmed.lines().filter { nativeFrameLine.containsMatchIn(it) }.joinToString("\n")
        }

        val lines = trimmed.lines()
        val backtraceStart = lines.indexOfFirst { it.trimStart().startsWith("backtrace:") }
        if (backtraceStart < 0) {
            return trimmed
        }

        val header = lines.take(backtraceStart).filter { line ->
            line.contains("ABI:") || line.startsWith("signal ", ignoreCase = true) ||
                line.startsWith("***")
        }
        val frames = mutableListOf<String>()
        for (i in backtraceStart until lines.size) {
            val line = lines[i]
            if (i > backtraceStart && line.isBlank()) {
                break
            }
            if (i > backtraceStart && line.trimStart().startsWith("---")) {
                break
            }
            frames.add(line)
        }
        return (header + frames).joinToString("\n").trim()
    }

    fun format(tombstone: ParsedTombstoneData): FormattedTombstone {
        val signalLabel = formatSignal(tombstone.signalName, tombstone.signalNumber)
        val crashThread = tombstone.threads[tombstone.tid]
            ?: tombstone.threads.values.firstOrNull { it.backtrace.isNotEmpty() }
        val frames = crashThread?.backtrace.orEmpty()

        val lines = mutableListOf<String>()
        lines.add("*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***")
        lines.add("ABI: '${tombstone.arch}'")
        if (tombstone.pid > 0) {
            lines.add("pid: ${tombstone.pid}, tid: ${tombstone.tid}, name: ${crashThread?.name.orEmpty()}")
        }
        if (signalLabel.isNotEmpty()) {
            lines.add("signal $signalLabel")
        }
        if (tombstone.abortMessage.isNotBlank()) {
            lines.add("Abort message: '${tombstone.abortMessage.trim()}'")
        }
        lines.add("backtrace:")

        frames.forEachIndexed { index, frame ->
            lines.add(formatFrameLine(index, frame, tombstone.memoryMappings))
        }

        return FormattedTombstone(
            text = lines.joinToString("\n").trim(),
            signal = signalLabel,
        )
    }

    data class FormattedTombstone(
        val text: String,
        val signal: String,
    )

    private fun formatSignal(name: String, number: Int): String {
        if (name.isBlank() && number == 0) {
            return ""
        }
        val signalName = name.trim().ifEmpty { "UNKNOWN" }
        return if (number != 0) {
            "$signalName ($number)"
        } else {
            signalName
        }
    }

    private fun formatFrameLine(
        index: Int,
        frame: ParsedBacktraceFrame,
        mappings: List<ParsedMemoryMapping>,
    ): String {
        val pcHex = frame.pc.toString(16).padStart(16, '0')
        val library = resolveLibrary(frame, mappings)
        val suffix = buildString {
            if (frame.functionName.isNotBlank()) {
                append(" (")
                append(frame.functionName)
                if (frame.functionOffset > 0) {
                    append('+')
                    append(frame.functionOffset)
                }
                append(')')
            }
            if (frame.buildId.isNotBlank()) {
                append(" (BuildId: ")
                append(frame.buildId.trim())
                append(')')
            }
        }
        return "      #${String.format(Locale.US, "%02d", index)} pc $pcHex  $library$suffix"
    }

    private fun resolveLibrary(
        frame: ParsedBacktraceFrame,
        mappings: List<ParsedMemoryMapping>,
    ): String {
        if (frame.fileName.isNotBlank()) {
            return frame.fileName.trim()
        }

        val mapping = mappings.firstOrNull { frame.pc >= it.beginAddress && frame.pc < it.endAddress }
        if (mapping != null && mapping.mappingName.isNotBlank()) {
            return mapping.mappingName
        }

        return "unknown"
    }
}
