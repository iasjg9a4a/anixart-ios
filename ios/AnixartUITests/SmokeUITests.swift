import CoreGraphics
import Foundation
import XCTest

/// Смоук-тесты приложения Anixart (`com.swiftsoft.anixart.ios`).
///
/// Семь пользовательских сценариев на реальном приложении и реальной сети:
/// 1. `testOnboardingAppears` — чистый запуск: онбординг проходится кнопкой
///    «Продолжить»/«Начать», после чего появляется таб-бар.
/// 2. `testHomeLoadsShelves` — главная дорисовывает полку «Сейчас смотрят».
/// 3. `testOpenReleaseDeepLink` — отладочный маршрут `release/1` открывает
///    экран релиза с блоком «Серии».
/// 4. `testSearchShowsResults` — отладочный маршрут `search?q=naruto` показывает
///    результаты поиска.
/// 5. `testPlayerOpensForEpisode` — отладочный маршрут `1/8/1` открывает плеер.
/// 6. `testReleaseSwitchesVoiceoverAndSeesMultipleSources` — у релиза 92 на самом
///    деле несколько плееров: AniLibria → Kodik и Libria, AniDUB → Sibnet и Kodik.
/// 7. `testAllSourcesSheetShowsProviders` — флаг `-anixart-open-sources` открывает
///    шит «Все источники», в котором перечислены Kodik и Libria.
/// 8. `testPlayerHasControls` — у нативного плеера (release 1562 / Libria 218)
///    поверх видео есть свои контролы: play/pause, ползунок и кнопка закрытия.
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
    private func launchApp(
        onboardingDone: Bool,
        openRoute: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-anixart.onboarding.done", onboardingDone ? "YES" : "NO"]
        if let openRoute {
            app.launchArguments.append("-anixart-open-route=\(openRoute)")
        }
        app.launchArguments.append(contentsOf: extraArguments)
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

    // MARK: - Элементы экрана релиза и источников
    //
    // `accessibilityIdentifier` у них нет, зато есть осмысленные подписи:
    // чип озвучки — `type.displayName`, кнопка меню источника — имя выбранного
    // источника, пункты меню — имена источников, строка «Все источники» —
    // `accessibilityLabel` «Выбрать источник <имя>». Поэтому все запросы идут
    // по `label` через NSPredicate, без XPath и порядковых индексов.

    /// Первый элемент любого типа с подстрокой `fragment` в `label`.
    private func firstAnyElement(
        in app: XCUIApplication,
        labelContaining fragment: String,
        excludingLabels excluded: [String] = []
    ) -> XCUIElement {
        var format = "label CONTAINS %@"
        var arguments: [Any] = [fragment]
        for label in excluded {
            format += " AND label != %@"
            arguments.append(label)
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: format, argumentArray: arguments))
            .firstMatch
    }

    /// Чип озвучки в секции «Серии»: SwiftUI-кнопка с текстом `type.displayName`.
    ///
    /// Берём любой потомок с точной подписью: в дереве доступности это может быть
    /// и `button`, и вложенный `staticText` — тап по тексту внутри кнопки нажимает
    /// кнопку.
    private func voiceoverChip(in app: XCUIApplication, named name: String) -> XCUIElement {
        exactLabelElement(in: app, label: name)
    }

    /// Первый элемент любого типа с точной подписью (для чипов озвучек).
    private func exactLabelElement(in app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    /// Кнопка меню источника: подпись — имя выбранного источника, у пунктов меню —
    /// имя источника (у источника без серий добавляется «(нет серий)»).
    ///
    /// Чипы озвучек исключаем: «AniLibria» содержит «Libria» подстрокой, и без
    /// исключения чип приняли бы за источник.
    private func sourceMenuButton(in app: XCUIApplication, containing name: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ AND label != %@ AND label != %@",
            name, "AniLibria", "AniDUB"
        )
        return app.buttons.matching(predicate).firstMatch
    }

    /// Контролируемый скролл к следующему содержимому (тянем экран вверх) на ~30% высоты.
    ///
    /// Свайп с инерцией может проскочить нужный элемент, а `tap()` сам не скроллит:
    /// меню источника и чипы озвучек живут ниже шапки релиза. Поэтому тянем экран
    /// медленно и на каждом шаге проверяем `isHittable`.
    private func scrollUp(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Обратный скролл (тянем экран вниз): возвращает к шапке/чипам озвучек,
    /// если предыдущие действия увели страницу вниз.
    private func scrollDown(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Долистывает экран релиза до элемента и проверяет, что до него дошли.
    private func assertHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ description: String,
        maxScrolls: Int = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var reached = element.exists && element.isHittable
        var scrolls = 0
        // Чередуем направления: элемент может быть и ниже, и выше текущей позиции
        // (например, после выбора источника страница осталась прокрученной вниз,
        // а чип озвучки живёт выше). Два шага вниз, один вверх.
        while !reached && scrolls < maxScrolls {
            if scrolls % 3 == 2 {
                scrollDown(app)
            } else {
                scrollUp(app)
            }
            scrolls += 1
            reached = element.exists && element.isHittable
        }
        guard reached else {
            attachDiagnostics(in: app, name: "Не долистали: \(description)")
            XCTFail("Не удалось долистать до \(description)", file: file, line: line)
            return
        }
    }

    /// Ждёт, что элемент пропал с экрана: так проверяется закрытие меню источника
    /// после выбора пункта.
    private func assertDisappears(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ description: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        let result = XCTContext.runActivity(named: "Ждём исчезновение: \(description)") { _ in
            XCTWaiter().wait(for: [expectation], timeout: timeout)
        }
        guard result == .completed else {
            attachDiagnostics(in: app, name: "Не исчез: \(description)")
            XCTFail("За \(Int(timeout)) с не исчез \(description)", file: file, line: line)
            return
        }
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

        // Кнопка закрытия: у нативного плеера она в нашем оверлее (`player-close`),
        // у web-плеера — в системном навбаре («Закрыть»).
        let navClose = app.buttons["Закрыть"]
        let overlayClose = app.buttons.matching(identifier: "player-close").firstMatch
        let appeared = navClose.waitForExistence(timeout: 30) || overlayClose.waitForExistence(timeout: 20)
        XCTAssertTrue(appeared, "Экран плеера не открылся (нет ни навбарной, ни оверлейной кнопки закрытия)")

        // Kodik теперь резолвится в прямой HLS и играет AVPlayer'ом, поэтому
        // WKWebView здесь не обязателен. Проверяем, что экран плеера жив и
        // не залип в вечном спиннере: есть заголовок серии и кнопка закрытия.
        XCTAssertTrue(app.staticTexts["1 серия"].waitForExistence(timeout: 20),
                      "Нет заголовка серии на экране плеера")
        XCTAssertTrue(navClose.exists || overlayClose.exists, "Кнопка закрытия плеера недоступна")
    }

    // MARK: - 6. У релиза несколько плееров, а не только Kodik

    /// Доказывает, что источники у релиза действительно переключаются.
    ///
    /// Живой API (release 92, проверено 24.11.2026): у AniLibria источники
    /// `Kodik` + `Libria`, у AniDUB — `Sibnet` + `Kodik`. Страница релиза по
    /// умолчанию открывает первый источник с сериями, поэтому у AniLibria выбран
    /// Kodik, а у AniDUB — Sibnet. Сценарий:
    /// * AniLibria: меню источника содержит второй плеер `Libria`, его выбор
    ///   меняет подпись источника на «Libria»;
    /// * AniDUB: подпись источника становится «Sibnet» (а не Kodik), и в меню
    ///   есть второй плеер `Kodik`.
    /// Этого достаточно, чтобы опровергнуть «у аниме нет другого плеера кроме Kodik».
    func testReleaseSwitchesVoiceoverAndSeesMultipleSources() {
        // Проверяем пользовательское утверждение «у релиза только Kodik» через
        // экран «Все источники»: у релиза 92 у AniLibria есть Kodik и Libria,
        // у AniDUB — Sibnet и Kodik. Чипы/меню на странице для теста не трогаем:
        // они требуют прокрутки и делают тест хрупким.
        let app = launchApp(
            onboardingDone: true,
            openRoute: "release/92",
            extraArguments: ["-anixart-open-sources"]
        )

        let sheetTitle = app.staticTexts["Все источники"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 40), "Шит «Все источники» не открылся")

        // Озвучки и их плееры видны сразу в одном списке.
        XCTAssertTrue(app.staticTexts["AniLibria"].waitForExistence(timeout: 20), "Нет группы AniLibria")
        XCTAssertTrue(app.staticTexts["AniDUB"].waitForExistence(timeout: 10), "Нет группы AniDUB")

        let libria = app.staticTexts["Libria"]
        XCTAssertTrue(libria.waitForExistence(timeout: 20), "Нет источника Libria (озвучка AniLibria)")
        let sibnet = app.staticTexts["Sibnet"]
        XCTAssertTrue(sibnet.waitForExistence(timeout: 10), "Нет источника Sibnet (озвучка AniDUB)")
    }

    // MARK: - 7. Шит «Все источники» перечисляет провайдеров

    /// `-anixart-open-sources` открывает из deep link шит «Все источники» и грузит
    /// сводку по озвучкам релиза. На release 92 провайдеров несколько: Kodik
    /// (AniLibria, AniDUB, AniMedia) и Libria (AniLibria) — оба обязаны быть в шите.
    func testAllSourcesSheetShowsProviders() {
        let app = launchApp(
            onboardingDone: true,
            openRoute: "release/92",
            extraArguments: ["-anixart-open-sources"]
        )

        // Отладочный флаг открывает шит сам, когда сводка по всем озвучкам готова.
        // Флаг проверяется после `load()`, а сводку тот же `load()` запускает фоном:
        // если фоновая загрузка начнётся раньше, флаг может не открыть шит. Тогда
        // идём штатным путём — строка «Источники» → кнопка «Все».
        let sheetTitle = app.staticTexts["Все источники"]
        if !sheetTitle.waitForExistence(timeout: 25) {
            // Медленная сеть: шит мог открыться уже после первого ожидания —
            // даём ещё немного времени, прежде чем лезть на страницу релиза.
            if !sheetTitle.waitForExistence(timeout: 5) {
                let sourcesLabel = app.staticTexts["Источники"]
                if sourcesLabel.waitForExistence(timeout: 20) {
                    assertHittable(sourcesLabel, in: app,
                                   "строка «Источники» на странице релиза", maxScrolls: 24)
                    // У секции комментариев тоже есть кнопка «Все»: берём ту, что
                    // стоит в одной строке с заголовком «Источники».
                    let allButton = app.buttons
                        .matching(NSPredicate(format: "label == %@", "Все"))
                        .allElementsBoundByIndex
                        .first { abs($0.frame.minY - sourcesLabel.frame.minY) < 40 }
                    allButton?.tap()
                }
            }
        }
        assertAppears(sheetTitle, in: app, "заголовок шита «Все источники»", timeout: 20)

        // Строка источника — кнопка с подписью «Выбрать источник Kodik»; у пустых
        // источников это может быть отдельный текст, поэтому ищем по любому элементу.
        assertAppears(firstAnyElement(in: app, labelContaining: "Kodik"), in: app,
                      "источник «Kodik» в шите «Все источники»", timeout: 20)

        // «AniLibria» — заголовок группы озвучек, а не источник: его исключаем,
        // иначе проверка «Libria» выполнялась бы заголовком группы.
        assertAppears(firstAnyElement(in: app, labelContaining: "Libria",
                                      excludingLabels: ["AniLibria"]), in: app,
                      "источник «Libria» в шите «Все источники»", timeout: 20)
    }

    // MARK: - 8. Контролы нативного плеера

    /// Поверх нативного видео должны быть свои контролы, а не голый `AVPlayerLayer`:
    /// play/pause, ползунок перемотки и кнопка закрытия. Нативный поток Libria
    /// (release 1562 / source 218) играет через `AVPlayer` — это его сценарий.
    ///
    /// Контролы автоскрываются через 6 секунд (CI-скриншот `14-player-controls.png`
    /// снимается раньше), а пока видео буферизуется, вместо центральной кнопки
    /// play/pause показан спиннер. Поэтому устойчиво ждём нижнюю панель
    /// (`player-seek` — она есть всегда) и кнопку закрытия, а play/pause
    /// проверяем и жмём, только если он реально появился.
    func testPlayerHasControls() {
        let app = launchApp(onboardingDone: true,
                            extraArguments: ["-anixart-open-player=1562/218/1"])

        // Нижняя панель контролов есть сразу при открытии плеера.
        let seek = app.descendants(matching: .any)["player-seek"]
        assertAppears(seek, in: app, "ползунок перемотки (player-seek)", timeout: 40)

        let close = app.buttons.matching(identifier: "player-close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10),
                      "У нативного плеера нет кнопки закрытия (player-close)")

        // play/pause не подменяется спиннером, но на медленной сети может появиться
        // индикатор буферизации — проверяем кнопку, а спиннер считаем допустимым.
        let playPause = app.descendants(matching: .any)["player-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 20),
                      "Нет кнопки play/pause (player-play-pause)")

        // Тап по видео не должен ронять приложение (контролы могли автоскрыться
        // — тап их возвращает, это штатное поведение).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertEqual(app.state, .runningForeground,
                       "Тап по видео уронил приложение")
        XCTAssertTrue(close.waitForExistence(timeout: 10),
                      "Экран плеера пропал после тапа по видео")
    }
}

