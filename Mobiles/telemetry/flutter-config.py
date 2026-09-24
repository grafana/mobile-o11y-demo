#!/usr/bin/env python3
"""Select the active local setup (or ordinary config) before a Flutter launch."""
import json
import os
from pathlib import Path
import sys

from configure import HERE, ROOT, write


def select(root=ROOT, here=HERE):
    app = root / 'Mobiles/flutter'
    explicit = os.environ.get('QUICKPIZZA_FLUTTER_CONFIG_FILE')
    active = here / '.runtime/active/flutter.json'
    source = Path(explicit).expanduser() if explicit else (
        active if active.is_file() else app / 'config.json')
    if not source.is_file():
        raise RuntimeError('Run python3 Mobiles/telemetry/setup.py, or create Mobiles/flutter/config.json first.')
    data = json.loads(source.read_text())
    destination = app / '.dart_tool/telemetry-config.json'
    write(destination, json.dumps(data, indent=2) + '\n')
    return destination


if __name__ == '__main__':
    try:
        print(select())
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError):
        print('Could not read Flutter configuration; check the selected JSON file.', file=sys.stderr)
        sys.exit(1)
