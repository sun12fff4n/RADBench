#!/usr/bin/env python3
"""Run prepare -> compile -> junit for real-world benchmark projects."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.run_project import main


if __name__ == "__main__":
    main(default_until="junit")
