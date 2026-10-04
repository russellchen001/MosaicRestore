#!/usr/bin/env python3
"""Slow progress fixture; never labelled Lada/CUDA restoration."""
import subprocess
import sys
import time
for progress in range(0, 100, 5):
    print(str(progress) + "%", flush=True)
    time.sleep(1)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", sys.argv[1], "-t", "2", sys.argv[2]], check=True)
