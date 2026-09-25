# SmallVoice

[English version](README.md)

SmallVoice - это нативная диктовка для macOS в строке меню. Зажмите клавишу и говорите: текст появится там,
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

## Установка релиза

SmallVoice не подписан сертификатом Apple Developer ID и не нотаризован: у проекта нет платного аккаунта
Apple Developer. Поэтому скачанную копию macOS откроет только после того, как вы один раз это разрешите.

1. Скачайте `SmallVoice.dmg` со страницы Releases, откройте его и перетащите SmallVoice в "Программы".
2. Снимите с приложения карантин загрузки:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SmallVoice.app
   ```

   Без Терминала: откройте SmallVoice, закройте предупреждение и нажмите "Всё равно открыть" в
   Системные настройки -> Конфиденциальность и безопасность.

Без постоянной подписи macOS считает каждую новую версию другим приложением. После обновления снова
разрешите микрофон, а в Системные настройки -> Конфиденциальность и безопасность -> Универсальный
доступ удалите старую запись SmallVoice и включите новую.

## Сборка из исходников

```bash
make install    # Release-сборка в /Applications и запуск
make test       # тесты движка (тестам распознавания нужна скачанная модель)
make build      # Debug-сборка в build/DerivedData
make dmg        # build/SmallVoice.dmg из Release-сборки
```

По умолчанию сборка подписывается ad-hoc, аккаунт разработчика Apple не нужен. Но тогда macOS считает
каждую пересборку новым приложением и снова спрашивает доступ к микрофону и Универсальному доступу.
Чтобы разрешения сохранялись, скопируйте `Config/Local.example.xcconfig` в `Config/Local.xcconfig`
(файл не попадает в git) и укажите там свою команду и bundle ID. Хватит и бесплатного сертификата
Apple Development из Xcode.

## Первый запуск

Окно настройки попросит:

- разрешить доступ к микрофону;
- включить Универсальный доступ (Системные настройки -> Конфиденциальность и безопасность ->
  Универсальный доступ), он нужен для горячей клавиши и вставки текста;
- один раз скачать модель речи (178 МБ).

Модель скачивается с Hugging Face на закреплённой ревизии, проверяется по SHA-256 и хранится в
`~/Library/Application Support/SmallVoice/Models/`.

## Как выпустить релиз

`make dmg` собирает `build/SmallVoice.dmg` из Release-сборки. CI (GitHub Actions, Xcode 26) заодно
запускает юнит-тесты движка и выкладывает этот образ с ad-hoc-подписью как артефакт сборки. Его и
публикуют вместе с инструкцией по установке выше.

С сертификатом Developer ID образ можно было бы подписать и нотаризовать через `scripts/notarize.sh`,
тогда он открывался бы везде без этих шагов:

```bash
xcrun notarytool store-credentials SmallVoice --apple-id you@example.com --team-id ABCDE12345
DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" scripts/notarize.sh
```

## Как устроено

```
Packages/ParakeetKit/   движок распознавания на MLX (Metal GPU), не зависит от приложения
  Weights.swift         тернарные веса без потерь переупаковываются в 2-битную квантизацию MLX
  Features.swift        лог-мел признаки
  Encoder.swift         субсэмплинг, 24 блока FastConformer, VAD-голова
  Decoder.swift         LSTM-предсказатель и жадное TDT-декодирование
  Segmenter.swift       нарезка длинного аудио по паузам
  ParakeetEngine.swift  actor: загрузка, прогрев, распознавание
SmallVoice/                 приложение (SwiftUI и AppKit)
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
SmallVoice.app/Contents/MacOS/SmallVoice --transcribe a.wav b.m4a   # распознать файлы, показать скорость
open SmallVoice.app --args --hud-demo [recording|hands-free|processing|success|message]
open SmallVoice.app --args --onboarding
```

## Сравнение с другими приложениями

SmallVoice - не единственная бесплатная диктовка для Mac. Во всех приложениях ниже речь распознаётся
на самом компьютере; разница в моделях, в том, что построено вокруг них, и в цене.

| Приложение | Лицензия | Модели речи | Платформы | Коротко |
|---|---|---|---|---|
| **SmallVoice** | MIT | Parakeet Redux (1.58-битная Parakeet TDT 0.6B v3), загрузка 178 МБ | macOS 26+, Apple Silicon | GPU через MLX: десятки миллисекунд на диктовку и около 250 МБ памяти, 25 языков. Сознательно минималистичен: без ИИ-переписывания, облака и аккаунтов |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | GPL-3.0 | Parakeet TDT v3 и v2, Parakeet Flash, Nemotron, Cohere, Whisper, Apple Speech | macOS 15+, Apple Silicon (Windows и iOS в планах) | Самый близкий "всё в одном": больше моделей (от 250 МБ до 3.5 ГБ), живой предпросмотр, режимы команд и правки текста, необязательная локальная или облачная ИИ-обработка |
| [EnviousWispr](https://github.com/saurabhav88/EnviousWispr) | GPL-3.0 | Parakeet TDT v3 (CoreML на Neural Engine), WhisperKit Large v3 Turbo | macOS 14+, Apple Silicon | Parakeet v3 и необязательная локальная полировка текста (её модель EG-1 закрыта); вместе с Whisper - 99 языков |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | исходники GPL-3.0, готовая сборка платная | Whisper (whisper.cpp), Parakeet (FluidAudio), SenseVoice | macOS 15+ | Самый настраиваемый: режимы под каждое приложение, учёт контекста, облачные провайдеры. Бесплатен, если собрать самому |
| [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) | MIT | Whisper (whisper.cpp), Parakeet (FluidAudio) | macOS, Apple Silicon | Запись с удержанием клавиши или кнопки мыши, очередь аудиофайлов |
| [Handy](https://github.com/cjpais/Handy) | MIT | Whisper (whisper.cpp), Parakeet v3 (GGUF) | macOS, Windows, Linux | Кроссплатформенное приложение на Rust и Tauri; загрузки начинаются от 490 МБ |
| [superwhisper](https://superwhisper.com) | условно бесплатно | на бесплатном плане только локальные модели Whisper | macOS, Windows, iOS, Android | Бесплатная диктовка без ограничений и без облака, но Parakeet, облачные модели и ИИ-режимы - в Pro |
| [MacWhisper](https://www.macwhisper.com/) | условно бесплатно | Whisper, Parakeet | macOS | Сделан для расшифровки файлов и встреч, а не для живой диктовки; в бесплатной версии только небольшие модели Whisper |
| Диктовка macOS | бесплатно, встроена | модель речи Apple | macOS | Ставить ничего не нужно, на Apple Silicon работает в основном на устройстве, но модель не выбрать и настроек почти нет |

Большинство из них работают на Whisper: до 99 языков ценой от нескольких сотен мегабайт до
нескольких гигабайт на диске и вывода на GPU. Parakeet TDT v3 покрывает 25 языков заметно меньшей
моделью. SmallVoice идёт на шаг дальше: в Parakeet Redux каждый вес энкодера равен -1, 0 или +1,
поэтому вся модель занимает 178 МБ и считается на 2-битных ядрах MLX. Отсюда диктовка за десятки
миллисекунд и около 250 МБ памяти в простое.

Отсутствие лишнего - тоже выбор: в SmallVoice нет ИИ-переписывания, режимов под приложения и облачных
провайдеров, нет сборок для Windows и Linux, и нужен macOS 26. Если это важно, смотрите в сторону
FluidVoice, EnviousWispr и VoiceInk.

## Приватность

Звук записывается только во время диктовки и не сохраняется на диск. Распознавание работает локально.
Единственное обращение к сети - разовая загрузка модели с Hugging Face. Недавние диктовки хранятся
только в памяти и исчезают при выходе.

## Лицензия и благодарности

SmallVoice распространяется по [лицензии MIT](LICENSE).

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
