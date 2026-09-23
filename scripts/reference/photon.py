# Optional: transcribes files with Photon, Moondream's own runtime for parakeet-redux, to compare
# against ParakeetKit by hand. Nothing in the build or the tests needs it.
#
# Photon ships in the `moondream` Python package (2.4.1 or later), and its CPU/GPU kernels come
# under a proprietary license: read Moondream's terms before installing it.
#
# Usage: DEVICES=cpu python photon.py a.wav [b.wav ...]   (uses the model folder the app downloads)
import os
import sys
import time

import moondream as md

model_dir = os.path.expanduser(
    "~/Library/Application Support/SmallVoice/Models/parakeet-redux/ab9eb5ef7b81f98211b3feb68e5a856cab71f913")
files = sys.argv[1:]
for device in os.environ.get("DEVICES", "cpu").split(","):
    with md.photon("moondream/parakeet-redux", device=device, model_path=model_dir) as speech:
        speech.transcribe(audio=files[0])  # warm-up
        for path in files:
            started = time.perf_counter()
            result = speech.transcribe(audio=path)
            elapsed = (time.perf_counter() - started) * 1000
            print(f"{device}\t{os.path.basename(path)}\t{elapsed:.0f} ms\t{result['text']}", flush=True)
