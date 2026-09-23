# Reference log-mel features for ParakeetKit's feature test, computed independently with librosa.
#
# Usage: python features.py in.wav out.bin   (needs numpy, soundfile, librosa)
#
# Settings follow NeMo's AudioToMelSpectrogramPreprocessor for Parakeet TDT: 16 kHz, pre-emphasis
# 0.97, 512-point FFT, 25 ms symmetric Hann window (400 samples), 10 ms hop, centred frames with
# zero padding, power spectrum, 128 Slaney mel filters, log(x + 2^-24), per-bin normalization over
# the n / 160 valid frames with the unbiased standard deviation plus 1e-5; the extra frame is zeroed.
import sys

import librosa
import numpy as np
import soundfile as sf

audio, rate = sf.read(sys.argv[1], dtype="float32")
assert rate == 16_000 and audio.ndim == 1

emphasised = np.concatenate([audio[:1], audio[1:] - 0.97 * audio[:-1]]).astype(np.float32)
spectrum = librosa.stft(
    emphasised, n_fft=512, hop_length=160, win_length=400, window=np.hanning(400),
    center=True, pad_mode="constant")
power = (np.abs(spectrum) ** 2).astype(np.float32)
filters = librosa.filters.mel(sr=16_000, n_fft=512, n_mels=128, htk=False, norm="slaney").astype(np.float32)
log_mel = np.log(filters @ power + 2.0**-24).T  # [frames, 128]

valid = audio.size // 160
head = log_mel[:valid]
features = (log_mel - head.mean(0)) / (head.std(0, ddof=1) + 1e-5)
features[valid:] = 0

print(features.shape, float(np.abs(features).max()))
features.astype(np.float32).tofile(sys.argv[2])
