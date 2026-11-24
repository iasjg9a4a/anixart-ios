# StubSwiftUI — typecheck iOS-кода Anixart на Linux

Локальный `swiftc` на этой машине не работает: `swiftc --version` завершается с
`-1073741502` (0xC0000142, DLL init failed) даже с полным PATH и путём в Runtimes.
Поэтому проверка идёт через Compiler Explorer (Swift 6.4.2, Linux x86-64).

## Как работает

`StubKit.swift` — минимальный фальшивый модуль SwiftUI/Combine/WebKit/AVKit/Security:
типы и сигнатуры, которые использует наш код, с пустыми телами. `check.py` склеивает
заглушку + исходники приложения, вырезая `import SwiftUI|Combine|WebKit|AVKit|Security`
(вырезает, но **сохраняет нумерацию строк** — вместо строки ставится пустая), и шлёт
в CE с `-typecheck -parse-as-library`. Диагностика переводится обратно в `файл:строка`.

```powershell
python check.py            # все экраны
python check.py home       # один экран
python check.py stub       # sanity-check самой заглушки
python check.py mutate     # контрольные поломки: стенд обязан их поймать
```

Собранные блобы складываются в `build/`; при разборе ошибок сырой ответ CE печатается в консоль.

## Что важно про заглушку

- `View` помечен `@MainActor` (как в iOS 18 SDK). Из-за этого актор-изоляция
  проверяется в «мягком» варианте: на Xcode 15 / iOS 17 SDK `View` не изолирован,
  и выводы про `@MainActor`-модели в `@StateObject` могут отличаться.
- `Color` конформен `View` **в extension**, чтобы изоляция не переехала на тип
  (иначе `Theme` с его `static let` не компилируется — это артефакт заглушки,
  в настоящем SwiftUI `Color` вне MainActor).
- `buildOptional` возвращает `C?` + `extension Optional: View` — как в SwiftUI.
  Без этого ломались все `if` без `else` внутри `@ViewBuilder`.
- `ToolbarItem` здесь `View`, а не `ToolbarContent` — содержимое тулбаров
  проверяется, но злоупотребления `ToolbarContent`-API нет.
- Security/Keychain — только константы и сигнатуры; `CFDictionary` = `[String: Any]`,
  поэтому приведение `query as CFDictionary` в `TokenStore` проверяется условно.
