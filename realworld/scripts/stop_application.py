#!/usr/bin/env python3
"""Stop started real-world benchmark applications."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.run_project import main


if __name__ == "__main__":
    main(default_stage="stop")
