# Test audio

Every clip here comes from Mozilla Common Voice, which is dedicated to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). The clips were resampled to 16 kHz
mono 16-bit PCM. `long.wav` joins six clips with 0.7 s of silence between them.

| Fixture | Common Voice clip | Sentence |
|---|---|---|
| `en.wav` | common_voice_en_17848807 | The little girl wanted to have a balloon, but was too shy to ask. |
| `ru.wav` | common_voice_ru_37920153 | Мы считаем, что совместно мы можем предпринимать важные шаги и успешно двигаться вперед. |
| `long.wav` | common_voice_en_39112047 | On the whole this kind of furniture has a relatively delicate look. |
| | common_voice_en_18062056 | They hope to get a hybrid embryo by merging the DNA of a different species. |
| | common_voice_en_18344534 | But here amongst ourselves let us speak out. |
| | common_voice_ru_38767086 | Вместе с тем, мы не собираемся потворствовать односторонним действиям Палестинской администрации. |
| | common_voice_ru_40001008 | Напротив, мы приветствуем и высоко оцениваем их вклад. |
| | common_voice_ru_19006605 | Господин Председатель, мы рассчитываем прилежно поработать с вами над докладом. |

The clips were taken from these Hugging Face mirrors of Common Voice:

- English: [Trelis/cv-en-scripted-test-500](https://huggingface.co/datasets/Trelis/cv-en-scripted-test-500)
  (Common Voice Scripted Speech 25.0, test split), revision `7f718b7a0cb0a5120d1483ef6f71e11b572d57b7`.
- Russian: [Sh1man/common_voice_21_ru](https://huggingface.co/datasets/Sh1man/common_voice_21_ru)
  (Common Voice 21.0, test split), revision `9868a070163572c0ebda83ebb96c7f56f8b56e18`.

Other files:

- `*.txt` hold the Common Voice sentences, the ground truth for the word-error-rate checks.
- `*.expected.txt` hold the engine's own output, a regression snapshot.
- `en.features.bin` holds the float32 log-mel reference for `en.wav`, made with `scripts/reference/features.py`.
