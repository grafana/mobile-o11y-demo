"""Attach source-relative OCR text retention to a completed fair comparison (macOS Vision)."""
import argparse
import json
import re
import subprocess
import unicodedata
from pathlib import Path


def normalize(lines):
    text = ' '.join(line['text'] for line in lines)
    return re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', text).lower()).strip()


def distance(a, b):
    previous = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1]+1, previous[j]+1, previous[j-1]+(x != y)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--ocr', required=True, help='Compiled ocr.swift executable')
    parser.add_argument('--candidates', nargs='+', help='Check only added candidates; retain the existing OCR evidence')
    args = parser.parse_args()
    root = args.directory.resolve()
    report = json.loads((root/'analysis.json').read_text())
    inputs = root/'ocr-input.json'
    paths = sorted((root/'inspection').glob('*.png'))
    if args.candidates:
        paths = [p for p in paths if p.name.startswith('source-') or any(p.name.startswith(c+'-') for c in args.candidates)]
    inputs.write_text(json.dumps([str(p) for p in paths]))
    output = root/'ocr.json'
    data = json.loads(output.read_text()) if args.candidates and output.exists() else {}
    latest = root/'ocr-latest.json'
    subprocess.run([args.ocr, str(inputs), str(latest)], check=True, timeout=300)
    data.update(json.loads(latest.read_text()))
    output.write_text(json.dumps(data, indent=2))
    for candidate in report['candidates']:
        if args.candidates and candidate['candidate'] not in args.candidates:
            continue
        checked = []
        characters = errors = 0
        for index in report['inspectionIndexes']:
            reference = normalize(data[str(root/'inspection'/f'source-{index}.png')])
            decoded = normalize(data[str(root/'inspection'/f'{candidate["candidate"]}-{index}.png')])
            assert reference, 'Cannot score an empty OCR reference'
            edit = distance(reference, decoded)
            characters += len(reference)
            errors += edit
            checked.append({'frame': index, 'referenceCharacters': len(reference), 'editDistance': edit,
                            'retention': max(0, 1-edit/len(reference)), 'reference': reference, 'candidate': decoded})
        candidate['ocr'] = {'referenceCharacters': characters, 'editDistance': errors,
                            'retention': max(0, 1-errors/characters), 'samples': checked}
    (root/'analysis.json').write_text(json.dumps(report, indent=2))
    count = len(args.candidates) if args.candidates else len(report['candidates'])
    print(root.name, 'OCR checked', count*len(report['inspectionIndexes']), 'candidate images')


if __name__ == '__main__':
    main()
