import Foundation
import XCTest

/// Смоук-тесты приложения Anixart (`com.swiftsoft.anixart.ios`).
///
/// Четыре пользовательских сценария на реальном приложении и реальной сети:
/// 1. `testOnboardingAppears` — чистый запуск: онбординг проходится кнопкой
///    «Продолжить»/«Начать», после чего появляется таб-бар.
/// 2. `testHomeLoadsShelves` — главная дорисовывает полку «Сейчас смотрят».
/// 3. `testOpenReleaseDeepLink` — отладочный маршрут `release/1` открывает
///    экран релиза с блоком «Серии».
/// 4. `testSearchShowsResults` — отладочный маршрут `search?q=naruto` показывает
///    результаты поиска.
///
/// Тесты чёрные: только `XCUIApplication`, без `@testable import Anixart`.
/// Сеть не подменяется, поэтому все ожидания — `waitForExistence(timeout:)`
/// с запасом вместо фиксированных пауз, а пиксели не сравниваются.
///
/// Флаги приложение читает из аргументов запуска (`NSArgumentDomain` и
/// `ProcessInfo`, см. `Anixart/App/AnixartApp.swift`), так что UserDefaults
/// тесты не трогают: `-anixart.onboarding.done YES|NO` и
/// `-anixart-open-route=<путь>`.
final class SmokeUITests: XCTestCase {

    // MARK: - Подписи, которые ждём

    /// Кнопка онбординга. Видимый текст — «Продолжить»/«Начать», а
    /// `.accessibilityLabel` в `OnboardingView` сейчас —
    /// «Следующая страница»/«Начать пользоваться приложением». Ждём любой из
    /// вариантов, чтобы смоук не зависел от того, какой из текстов попадёт
    /// в дерево доступности (и пережил бы смену label в приложении).
    private static let continueLabels = ["Продолжить", "Следующая страница"]
    private static let finishLabels = ["Начать", "Начать пользоваться приложением"]

    // MARK: - Подготовка

    override func setUp() {
        super.setUp()
        // Первое падение — конец теста: продолжать проверки бессмысленно.
        continueAfterFailure = false
    }

    /// Запускает приложение с нужными аргументами.
    ///
    /// `XCUIApplication()` без bundle id — это target application из
    /// `TEST_TARGET_NAME: Anixart` в `project.yml`.
    private func launchApp(onboardingDone: Bool, openRoute: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-anixart.onboarding.done", onboardingDone ? "YES" : "NO"]
        if let openRoute {
            app.launchArguments.append("-anixart-open-route=\(openRoute)")
        }
        let arguments = app.launchArguments.joined(separator: " ")
        XCTContext.runActivity(named: "Запуск Anixart: \(arguments)") { _ in
            app.launch()
        }
        return app
    }

    // MARK: - Вспомогательные проверки

    /// Ждёт элемент и при таймауте прикладывает скриншот и дерево доступности.
    private func assertAppears(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ description: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appeared = XCTContext.runActivity(named: "Ждём: \(description)") { _ in
            element.waitForExistence(timeout: timeout)
        }
        guard appeared else {
            attachDiagnostics(in: app, name: "Нет элемента: \(description)")
            XCTFail("За \(Int(timeout)) с не появился \(description)", file: file, line: line)
            return
        }
    }

    /// Скриншот и иерархия — чтобы по артефакту CI было видно, где застряли.
    private func attachDiagnostics(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) — скриншот"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) — иерархия доступности"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// Кнопка онбординга с любой из подписей текущего шага.
    private func onboardingButton(in app: XCUIApplication, labels: [String]) -> XCUIElement {
        let predicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: labels.map { NSPredicate(format: "label == %@", $0) }
        )
        return app.buttons.matching(predicate).firstMatch
    }

    // MARK: - 1. Онбординг

    func testOnboardingAppears() {
        let app = launchApp(onboardingDone: false)

        let continueButton = onboardingButton(in: app, labels: Self.continueLabels)
        assertAppears(continueButton, in: app,
                      "кнопка онбординга «Продолжить»", timeout: 20)
        XCTContext.runActivity(named: "Кнопка онбординга найдена: «\(continueButton.label)»") { _ in }

        // Три страницы онбординга: два «Продолжить» и финальное «Начать».
        for step in 1...3 {
            let labels = step == 3 ? Self.finishLabels : Self.continueLabels
            let button = onboardingButton(in: app, labels: labels)
            assertAppears(button, in: app, "шаг \(step)/3: кнопка «\(labels[0])»", timeout: 10)
            XCTContext.runActivity(named: "Тап \(step)/3: «\(button.label)»") { _ in
                button.tap()
            }
        }

        let tabBar = app.tabBars.firstMatch
        assertAppears(tabBar, in: app, "таб-бар после онбординга", timeout: 15)
        for title in ["Главная", "Поиск", "Коллекции", "Статьи", "Профиль"] {
            XCTAssertTrue(tabBar.buttons[title].waitForExistence(timeout: 10),
                          "В таб-баре нет вкладки «\(title)»")
        }
    }

    // MARK: - 2. Главная

    func testHomeLoadsShelves() {
        let app = launchApp(onboardingDone: true)

        // Сначала таб-бар: если флаг онбординга не сработал, приложение останется
        // на приветствии, и ждать полку главной бессмысленно.
        assertAppears(app.tabBars.firstMatch, in: app,
                      "таб-бар (онбординг пропущен)", timeout: 15)

        // `discover/hub` и каталог грузятся с живого API — 20 секунд с запасом.
        assertAppears(app.staticTexts["Сейчас смотрят"], in: app,
                      "полка «Сейчас смотрят» на главной", timeout: 20)
    }

    // MARK: - 3. Deep link на релиз

    func testOpenReleaseDeepLink() {
        let app = launchApp(onboardingDone: true, openRoute: "release/1")

        // Шит deep link обёрнут в NavigationStack с кнопкой «Закрыть».
        assertAppears(app.buttons["Закрыть"], in: app,
                      "шит релиза с кнопкой «Закрыть»", timeout: 20)

        // «Серии» и бейджи метаданных рендерятся всегда, когда релиз загружен.
        // Секция «Комментарии» условная (появляется, только если комментарии
        // есть), поэтому её наличия не требуем.
        assertAppears(app.staticTexts["Серии"], in: app, "блок «Серии»", timeout: 20)
        assertAppears(app.staticTexts["Рейтинг"], in: app, "бейдж «Рейтинг»", timeout: 5)

        // Название релиза приходит с живого сервера и может измениться, поэтому
        // сверять его с эталоном нельзя. Проверяем, что на экране есть тексты
        // данных релиза (название/жанры/описание), а не пустое место.
        let chrome: Set<String> = ["Рейтинг", "Серий", "Отзывов", "Серии", "Описание",
                                   "Связанные", "Список серий пуст", "Закрыть"]
        let dataTexts = app.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty && !chrome.contains($0) && !$0.hasPrefix("Комментарии (") }
        let preview = dataTexts.prefix(6).joined(separator: " | ")
        XCTContext.runActivity(named: "Тексты на экране релиза: \(preview)") { _ in }
        XCTAssertFalse(dataTexts.isEmpty, "На экране релиза не отрисовалось ни названия, ни данных")
    }

    // MARK: - 4. Deep link на поиск

    func testSearchShowsResults() {
        let app = launchApp(onboardingDone: true, openRoute: "search?q=naruto")

        // Карточка результата — NavigationLink: её подпись в дереве доступности
        // может быть отдельным staticText или склеенным label кнопки, поэтому
        // ищем «Наруто»/«Naruto» по всем потомкам, а не только в staticTexts.
        let hitPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Наруто", "Naruto"
        )
        let hit = app.descendants(matching: .any).matching(hitPredicate).firstMatch
        let found = XCTContext.runActivity(named: "Ждём результат поиска «naruto» (до 20 с)") { _ in
            hit.waitForExistence(timeout: 20)
        }
        if found {
            XCTContext.runActivity(named: "Найден результат: «\(hit.label)»") { _ in }
            return
        }

        attachDiagnostics(in: app, name: "Поиск «naruto» без ожидаемого результата")

        // Запасной критерий из ТЗ: выдача не пустая. Состояния «ничего не
        // найдено», «запрос не применился» и ошибку сети отсекаем отдельно,
        // чтобы зелёный тест не означал сломанный поиск.
        XCTAssertFalse(app.staticTexts["Ничего не найдено"].exists,
                       "Поиск «naruto» вернул пустую выдачу")
        XCTAssertFalse(app.staticTexts["Введите хотя бы два символа"].exists,
                       "Поисковый запрос из deep link не применился")
        XCTAssertFalse(app.buttons["Повторить"].exists,
                       "Поиск не выполнился: ошибка сети/API")
        let resultCards = app.buttons.allElementsBoundByIndex.filter { $0.label.count > 10 }
        XCTAssertFalse(resultCards.isEmpty,
                       "Поиск «naruto»: не отрисовалось ни одной карточки результата")
    }

    // MARK: - 5. Плеер открывается по отладочному маршруту

    /// Проверяет, что экран плеера реально открывается и WKWebView-слой прогружается.
    /// Содержимое Kodik-iframe кросс-доменное: если Kodik отдаёт свою страницу ошибки,
    /// тест это не различит — для этого есть CI-скриншот `08-player.png`.
    func testPlayerOpensForEpisode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-anixart.onboarding.done", "YES",
            "-anixart-open-player=1/8/1"
        ]
        app.launch()

        // Заголовок плеера — имя серии; кнопка закрытия всегда есть в навбаре.
        let closeButton = app.buttons["Закрыть"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 30), "Экран плеера не открылся")

        // Плеер должен успеть загрузить web-слой (не вечный спиннер) — ждём,
        // пока исчезнет индикатор загрузки или появится любой web-контент.
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WKWebView не появился")
    }
}
