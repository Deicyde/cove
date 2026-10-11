#!/usr/bin/python3
"""Test double for `kitten @ send-text --from-file`; copies bytes to --to."""

import pathlib
import sys


args = sys.argv[1:]
target = args[args.index("--to") + 1]
source = args[args.index("--from-file") + 1]
target_path = pathlib.Path(target)
temporary = target_path.with_name(target_path.name + ".tmp")
temporary.write_bytes(pathlib.Path(source).read_bytes())
temporary.replace(target_path)
