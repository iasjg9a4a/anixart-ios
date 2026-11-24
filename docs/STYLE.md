# Стиль кода iOS-клиента Anixart

Документ описывает, как писать код в `ios/Anixart`. Он дополняет `.swiftlint.yml`
в корне репозитория: линтер ловит механические нарушения, здесь — то, что он
проверить не может.

Коротко о стеке: SwiftUI, Swift 5.9, deployment target **iOS 16.0** (см.
`ios/project.yml`), проект генерируется `xcodegen`, сторонних библиотек нет.
Код — по-английски, интерфейс и комментарии — по-русски.

---

## 1. Базовое форматирование

- Отступ — **4 пробела**, табы запрещены.
- Одна инструкция — одна строка; `;` не используем.
- Длина строки — до **140** символов (жёсткий предел линтера — 200).
  Длинный вызов переносится так:

  ```swift
  let target = try await api.episodeTarget(
      releaseId: releaseId,
      sourceId: sourceId,
      position: episode.position
  )
  ```

- Фигурная скобка — на той же строке, что и объявление; `else` — на одной
  строке с закрывающей скобкой: `} else if let message = ...`.
- Пробелы вокруг бинарных операторов и после запятой; перед двоеточием пробела
  нет: `self.releaseId = releaseId`, `case .release(id: id)`.
- «Висячие» запятые в коллекциях не ставим.
- Модификаторы вьюхи — цепочкой, каждый на новой строке:

  ```swift
  Text(release.displayTitle)
      .font(.caption.weight(.medium))
      .foregroundStyle(Theme.textPrimary)
      .lineLimit(2)
  ```

- Пустая строка между блоками — максимум одна подряд; файл заканчивается
  одним переводом строки. Пробелов в конце строк нет (это проверяет линтер).

## 2. Именование

- Типы — `UpperCamelCase`, суффикс отражает роль:
  `ReleaseView`, `HomeViewModel`, `Session`, `APIClient`, `TokenStore`,
  `DeepLinkRouter`, `ProfileListStatus`, `PlaybackRequest`, `APIError`,
  `Discover`, `CollectionBrief`, `InterestingItem`.
- Методы и свойства — `lowerCamelCase`. Метод начинается с глагола:
  `load()`, `refreshProfile()`, `signIn(login:password:)`, `push(_:)`, `play(_:)`.
- `Bool` — с префиксом `is`/`has`/`can`/`should`:
  `isLoading`, `isAuthorized`, `isWatched`, `canLike`, `isMyProfile`.
- ViewModel называется по экрану: `HomeView` → `HomeViewModel`,
  `ReleaseView` → `ReleaseViewModel`, `CollectionsView` → `CollectionsViewModel`.
- Короткие имена допустимы там, где контекст однозначен: `id`, `x`, `q`
  (поэтому в линтере `identifier_name.min_length: 1`). Не сокращайте
  «наполовину»: `rel` вместо `release` — плохо.
- UI-строки — по-русски, имена в коде — по-английски. Не смешивайте:
  `HomeViewModel.load()`, а не `HomeViewModel.загрузить()`.
- Константы — `static let` в `Theme` или в локальном `enum`, не глобальные
  переменные. Ключи `UserDefaults` — с префиксом `anixart.`:
  `"anixart.profile.id"`.
- Вложенные типы (например `HomeViewModel.Shelf`) — только если тип нужен
  одному экрану. Общие — в `Components/` или `Models/`.

## 3. Структура файла: ViewModel + View вместе

Один экран — один файл: `ios/Anixart/Features/<Feature>/<Name>View.swift`.
В нём — и ViewModel, и View. Порядок частей:

```swift
import SwiftUI

// MARK: - Модель экрана
// (локальные типы состояния, если нужны)

@MainActor
final class NameViewModel: ObservableObject { ... }

// MARK: - Экран

struct NameView: View {
    @StateObject private var model = NameViewModel()

    var body: some View { ... }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View { ... }
}
```

Правила:

- ViewModel идёт первой, View — второй; вспомогательные подвьюхи — ниже View
  в том же файле.
- Разделы помечаются `// MARK: - <Название>` по-русски
  (`// MARK: - Загрузка`, `// MARK: - Экран`).
- Исключения из «всё в одном файле»: `App/Session.swift` (глобальное
  состояние), `Core/APIClient.swift`, `Core/TokenStore.swift`,
  `Models/Models.swift`, общие компоненты `Components/Components.swift`.
- Файл держим **до ~400 строк**. Перерос — выносите подвьюхи/полки в
  отдельный файл той же папки, как `Home/BannerShelfView.swift` или
  `Player/PlaybackProgress.swift`. `Models.swift` — реестр моделей, для него
  исключение (лимит линтера выше).
- Общие элементы интерфейса не дублируем: `RemoteImage`, `ReleasePoster`,
  `ReleaseCard`, `ShelfView`, `ChipView`, `LoadingView`, `ErrorStateView`
  живут в `Components/Components.swift`.
- Цвета, радиусы и отступы — только из `Theme` (`App/Theme.swift`).
  Хардкод `Color(hex:)` во вьюхах запрещён; готовые модификаторы —
  `.cardSurface()` и `.screenBackground()`.
- Сеть — только через `APIClient.shared` и только из ViewModel.

## 4. @MainActor, состояние, загрузка данных

- **Каждая** ViewModel — `@MainActor final class ...: ObservableObject`.
  Это обязательно: без `@MainActor` SwiftUI будет ругаться на изменение
  `@Published` из фонового контекста.
- Данные экрана — `@Published private(set) var`: менять их может только сама
  ViewModel. `@Published var` — только если View нужен двусторонний биндинг
  (пример: `playback` в `ReleaseViewModel` для `.sheet(item:)`).
- Бизнес-состояние во View не храним: там только `@State` для локального
  UI (`showsAllComments`, `selectedPage`) и `@StateObject` для модели.
- Зависимости — `private let api = APIClient.shared`, без синглтонов,
  разбросанных по вьюхам.
- Шаблон загрузки (одинаковый на всех экранах):

  ```swift
  func load() async {
      if isLoading { return }          // защита от повторного запуска
      isLoading = true
      errorMessage = nil
      defer { isLoading = false }

      do {
          async let first = api.discover()
          async let second = api.catalog(page: 1)
          // ...
      } catch {
          errorMessage = error.localizedDescription
      }
  }
  ```

- Независимые запросы запускаются параллельно через `async let`
  (см. `HomeViewModel.load()`).
- Подключение к View:

  ```swift
  @StateObject private var model = HomeViewModel()
  // экран с параметром:
  _model = StateObject(wrappedValue: ReleaseViewModel(releaseId: releaseId))

  var body: some View {
      NavigationStack {
          ScrollView { content }
              .screenBackground()
              .refreshable { await model.load() }
              .navigationTitle("Главная")
              .task { await model.load() }
      }
  }
  ```

- Перезагрузка из замыкания — `Task { await model.load() }`.
- `UIApplication`, `DispatchQueue.main` и `Timer` во вьюхах не используем.

## 5. Ошибки и состояния экрана

- `APIClient` бросает `APIError` (`Core/APIClient.swift`). Это
  `LocalizedError`: `errorDescription` уже содержит русский текст
  («Нужен вход в аккаунт Anixart», «Сервер вернул пустой ответ» и т.д.).
  Поэтому в ViewModel пишем ровно `errorMessage = error.localizedDescription`.
- Ошибка живёт в ViewModel: `@Published private(set) var errorMessage: String?`.
  Перед каждой загрузкой — `errorMessage = nil`.
- `errorMessage` — готовый для пользователя текст, а не код ответа, JSON
  или `String(describing: error)`.
- Специальные случаи разбираются через `as? APIError`:

  ```swift
  } catch {
      if let apiError = error as? APIError, apiError == .unauthorized {
          signOut()
      } else {
          errorMessage = error.localizedDescription
      }
  }
  ```

- Пустой ответ сервера — не ошибка: `{"code": 0}` без `content` декодируется
  пустым списком. Используйте `?? []` и проверки `!items.isEmpty`.
- Запрещено: `try!`, `as!`, `fatalError` для сетевых ошибок, «голые»
  алерты с техническим текстом.
- `force_unwrapping` включён как **предупреждение**. Новый код пишется без
  `!`: `guard let`, `if let`, `??`. В `Models.swift` остались исторические
  `title!` после `title?.isEmpty == false` — это легаси, копировать не нужно.
- Состояния экрана показываются в таком порядке (см. `HomeView.content` и
  `CollectionsView.content`):

  1. `isLoading && данные пусты` → `LoadingView`;
  2. `errorMessage != nil && данные пусты` → `ErrorStateView(message:retry:)`;
  3. данные пусты → заглушка (иконка + пояснение);
  4. иначе — контент.

## 6. Строки и комментарии

- Все пользовательские строки — **по-русски и прямо в коде**. Локализации
  через `.strings`/`NSLocalizedString` в проекте нет; не заводите её
  для одной строки.
- Числа и оценки форматируются явно: `String(format: "%.2f", grade)`,
  прочерк для пустого значения — `"—"`, разделитель подзаголовка — `" · "`.
  Склонения проверяем руками: «1 серия», «2 серии», «5 серий».
- Комментарии — **по-русски**. `///` — для типов, методов и неочевидных
  свойств; `//` — внутри тела.
- Комментарий объясняет «почему», а не «что»:

  ```swift
  /// Серии приходят из разных источников, поэтому позиция сама по себе не уникальна.
  var id: String { "\(sourceId ?? 0)-\(position)" }
  ```

- `// MARK: - <Раздел>` — русский, ровно с пробелом и дефисом.
- `TODO:`/`FIXME:` допустимы (правило `todo` в линтере отключено), но перед
  PR их лучше закрыть или оформить задачей.

## 7. Запреты (deployment target iOS 16.0)

- **`#Preview` — запрещён.** Превью-макросы в проекте не используются.
- **`@Observable` — запрещён.** Только `ObservableObject` +
  `@Published`/`@StateObject`/`@ObservedObject`/`@EnvironmentObject`.
- **API iOS 17+ — запрещены** без острой необходимости и `#available`:
  Observation (`@Observable`, `@Bindable`), SwiftData (`@Model`, `@Query`,
  `ModelContainer`), `ContentUnavailableView`, `.onChange(of:initial:)`,
  `.scrollPosition`, `.symbolEffect`, `.sensoryFeedback`,
  `.containerRelativeFrame`.
- `NavigationView` устарел — используем `NavigationStack`.
- `foregroundColor` устарел — используем `foregroundStyle`.
- Сторонние SPM-зависимости не добавляем.
- UIKit — только через `UIViewRepresentable` и только для того, чего нет
  в SwiftUI (плеер: `AVPlayer`, `WKWebView`), причём `private struct`.
- Если без API iOS 17 никак: `if #available(iOS 17, *) { ... } else { ... }`,
  fallback обязателен, рядом комментарий с причиной.

## 8. Лимиты и SwiftLint

Конфиг — `../.swiftlint.yml` в корне репозитория. Запуск из корня:

```bash
swiftlint lint --config .swiftlint.yml
```

| Что | Предупреждение | Ошибка |
| --- | --- | --- |
| Длина строки | 140 | 200 |
| Длина файла | 600 | 900 |
| Тело типа | 400 | 600 |
| Тело функции | 80 | 120 |
| Параметров в функции | 6 | 8 |
| Цикломатическая сложность | 15 | 25 |
| Пустых строк подряд | 1 | — |
| Длина имени | min 1, max 45 | min 1, max 60 |

Ключевые правила:

- `force_cast`, `force_try` — ошибки (в клиенте их нет и быть не должно);
- `force_unwrapping` — предупреждение (см. §5);
- `empty_count` — `.isEmpty` вместо `.count == 0`;
- `identifier_name` с `min_length: 1` — из-за `id`/`x`/`q`;
- включены `redundant_optional_initialization`, `unused_closure_parameter`,
  `trailing_whitespace`, `vertical_whitespace`, `colon`, `comma`,
  `opening_brace`;
- `todo` и `trailing_comma` отключены;
- исключены `ios/tools/StubSwiftUI/build` (генерация для Linux-typecheck)
  и `ios/Anixart.xcodeproj` (создаётся `xcodegen`).

Точечное отключение правила — только с пояснением:

```swift
// swiftlint:disable:next force_unwrapping — URL гарантированно валиден, константа
let baseURL = URL(string: "https://api-s.anixsekai.com/")!
```

Массовые `swiftlint:disable` в начале файла запрещены.
Известное исключение: длинная константа User-Agent в `Player/PlayerView.swift`
(171 символ) — `line_length` предупредит; переносить строку не нужно.

## 9. Как добавить новый экран

1. Определите место: новый раздел — `ios/Anixart/Features/<Feature>/`,
   файл `<Name>View.swift`. Подключать файл в Xcode не нужно: `project.yml`
   забирает всё из `ios/Anixart` (после этого — `xcodegen generate`).
2. Создайте ViewModel по шаблону из §4:

   ```swift
   // MARK: - Модель экрана

   @MainActor
   final class NameViewModel: ObservableObject {
       @Published private(set) var items: [Release] = []
       @Published private(set) var isLoading = false
       @Published private(set) var errorMessage: String?

       private let api = APIClient.shared

       func load() async {
           if isLoading { return }
           isLoading = true
           errorMessage = nil
           defer { isLoading = false }

           do {
               items = try await api.catalog(page: 1).content
           } catch {
               errorMessage = error.localizedDescription
           }
       }
   }
   ```

3. Создайте View с `NavigationStack`, `.screenBackground()`, `.task`,
   `.refreshable`, `.navigationTitle` (русский) и `@ViewBuilder private var
   content` с четырьмя состояниями из §5.
4. Экран с параметром — `let`-свойство + `init`, внутри
   `_model = StateObject(wrappedValue: NameViewModel(id: id))`
   (образец: `ReleaseView`, `UserProfileView`).
5. Встроенные фрагменты вынесите в отдельные `private struct` или в
   `Components/Components.swift`, если они переиспользуются.
6. Навигация: обычный переход — `NavigationLink { NameView() } label: { ... }`;
   экран по deep link — добавьте `case` в `AppRoute` и разбор в
   `DeepLinkRouter` (`App/DeepLinkRouter.swift`).
7. Отдельный пункт таба — `tabItem` в `RootView` (`App/AnixartApp.swift`).
8. Прогоните чек-лист ниже.

## 10. Чек-лист перед коммитом

- [ ] отступы 4 пробела, строки ≤ 140, нет пробелов в конце строк;
- [ ] ViewModel — `@MainActor final class ...: ObservableObject`,
      данные — `@Published private(set)`;
- [ ] ошибки — через `errorMessage` и `APIError`, без `try!`/`as!`;
- [ ] loading / error / empty / content — все четыре состояния;
- [ ] UI-строки и комментарии по-русски, `// MARK: -` оформлены;
- [ ] нет `#Preview`, `@Observable` и API iOS 17;
- [ ] цвета/радиусы — из `Theme`, общие вьюхи — из `Components`;
- [ ] `swiftlint lint --config .swiftlint.yml` без новых ошибок;
- [ ] `xcodegen generate` + сборка (`ios/tools/check.sh` на macOS) проходят.
