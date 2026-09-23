# NoType

[English version](README.md)

NoType - это нативная диктовка для macOS в строке меню. Зажмите клавишу и говорите: текст появится там,
где стоит курсор. Речь распознаётся прямо на Mac моделью
[Parakeet Redux](https://huggingface.co/moondream/parakeet-redux). Это 1.58-битная версия NVIDIA
Parakeet TDT 0.6B v3: 25 языков, включая русский и английский, с пунктуацией и регистром. Ничего не
уходит с компьютера.

## Как пользоваться

| Действие | Что происходит |
|---|---|
| Зажать правый ⌥ и говорить | Идёт запись; отпустили клавишу - текст вставлен (push-to-talk) |
| Коротко нажать правый ⌥ | Запись без рук (в индикаторе появляется замок); повторное нажатие завершает её |
| Esc во время записи | Отмена без вставки |
| ⌥ вместе с другой клавишей | Обычное сочетание клавиш, диктовка не начинается |

- Клавишу можно сменить в настройках: правый ⌘, Fn (🌐) или любое своё сочетание.
- Пока идёт запись и распознавание, внизу экрана видна капсула Liquid Glass: живая волна голоса,
  затем мягкая бегущая волна обработки, затем галочка.
- Текст вставляется через буфер обмена, после чего прежнее содержимое буфера возвращается. "Умный
  пробел" ставит пробел, если вы продолжаете фразу.
- В меню хранятся последние 10 диктовок, по клику текст копируется.
- Длинные диктовки режутся на части до 30 секунд по паузам, которые находит VAD-голова самой модели,
  и распознаются прямо во время записи. Поэтому после отпускания клавиши ждать почти не приходится.

## Требования

- macOS 26 или новее, Apple Silicon.
- Для сборки: Xcode 26 или новее с Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
  и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Сборка

```bash
make install    # Release-сборка в /Applications и запуск
make test       # тесты движка (тестам распознавания нужна скачанная модель)
make build      # Debug-сборка в build/DerivedData
make dmg        # build/NoType.dmg из Release-сборки
```

По умолчанию сборка подписывается ad-hoc, аккаунт разработчика Apple не нужен. Но тогда macOS считает
каждую пересборку новым приложением и снова спрашивает доступ к микрофону и Универсальному доступу.
Чтобы разрешения сохранялись, скопируйте `Config/Local.example.xcconfig` в `Config/Local.xcconfig`
(файл не попадает в git) и укажите там свою команду и bundle ID.

При первом запуске окно настройки попросит:

- разрешить доступ к микрофону;
- включить Универсальный доступ (Системные настройки -> Конфиденциальность и безопасность ->
  Универсальный доступ), он нужен для горячей клавиши и вставки текста;
- один раз скачать модель речи (178 МБ).

Модель скачивается с Hugging Face на закреплённой ревизии, проверяется по SHA-256 и хранится в
`~/Library/Application Support/NoType/Models/`.

## Релизы

`make dmg` упаковывает сборку с той подписью, которая настроена. Чтобы образ открывался на любом Mac без
предупреждений Gatekeeper, нужен сертификат Developer ID (платная программа Apple Developer) и
нотаризация. Её делает `scripts/notarize.sh`:

```bash
xcrun notarytool store-credentials NoType --apple-id you@example.com --team-id ABCDE12345
DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" scripts/notarize.sh
```

CI (GitHub Actions, Xcode 26) собирает приложение, запускает юнит-тесты движка и выкладывает образ с
ad-hoc-подписью как артефакт сборки.

## Как устроено

```
Packages/ParakeetKit/   движок распознавания на MLX (Metal GPU), не зависит от приложения
  Weights.swift         тернарные веса без потерь переупаковываются в 2-битную квантизацию MLX
  Features.swift        лог-мел признаки
  Encoder.swift         субсэмплинг, 24 блока FastConformer, VAD-голова
  Decoder.swift         LSTM-предсказатель и жадное TDT-декодирование
  Segmenter.swift       нарезка длинного аудио по паузам
  ParakeetEngine.swift  actor: загрузка, прогрев, распознавание
NoType/                 приложение (SwiftUI и AppKit)
  Dictation/            логика клавиши, запись с микрофона, вставка текста
  Input/                горячие клавиши, разрешения
  Model/                загрузка и проверка модели
  UI/                   индикатор, меню, настройки, окно первого запуска
```

ParakeetKit - это реализация архитектуры Parakeet TDT на Swift (в том виде, как она опубликована в NVIDIA
NeMo и Hugging Face transformers) для тернарного формата весов этой модели. Каждый вес энкодера Parakeet
Redux равен -1, 0 или +1, умноженному на масштаб группы. Это в точности ложится на 2-битную affine-
квантизацию MLX, поэтому веса занимают около 150 МБ и идут через квантизованное умножение матриц MLX.

Во время разработки вывод сверялся с Photon, собственным рантаймом Moondream, и совпадал посимвольно.
Тесты проверяют:

- переупаковку весов бит в бит;
- лог-мел признаки против независимого расчёта на librosa;
- распознавание английских, русских и смешанных длинных записей Common Voice (CC0): против
  произнесённых фраз и против закреплённого эталона.

Скорость на M3 Pro (Release):

| Аудио | Время до текста |
|---|---|
| 5.3 с | 60 мс |
| 8.3 с | 79 мс |
| 41.9 с | 405 мс |

Модель вместе с прогревом загружается примерно за 0.4 с. В простое приложение не тратит CPU и занимает
около 250 МБ памяти, большая часть которой - веса модели.

### Отладочные флаги

```bash
NoType.app/Contents/MacOS/NoType --transcribe a.wav b.m4a   # распознать файлы, показать скорость
open NoType.app --args --hud-demo [recording|hands-free|processing|success|message]
open NoType.app --args --onboarding
```

## Приватность

Звук записывается только во время диктовки и не сохраняется на диск. Распознавание работает локально.
Единственное обращение к сети - разовая загрузка модели с Hugging Face. Недавние диктовки хранятся
только в памяти и исчезают при выходе.

## Лицензия и благодарности

NoType распространяется по [лицензии MIT](LICENSE).

- Модель речи: [Parakeet Redux](https://huggingface.co/moondream/parakeet-redux) от Moondream на основе
  [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), лицензия
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Модели нет в репозитории, приложение
  скачивает её само.
- [mlx-swift](https://github.com/ml-explore/mlx-swift) (MIT), вместе с ним
  [swift-numerics](https://github.com/apple/swift-numerics) и
  [swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0).
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT).
- Тестовое аудио: записи [Mozilla Common Voice](https://commonvoice.mozilla.org), CC0 1.0, подробности в
  [Packages/ParakeetKit/Tests/ParakeetKitTests/Fixtures/SOURCES.md](Packages/ParakeetKit/Tests/ParakeetKitTests/Fixtures/SOURCES.md).
