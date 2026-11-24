import Foundation
import SwiftUI

// MARK: - Фильтр каталога

/// Фильтр каталога `GET filter/{page}` (нумерация страниц — с нуля).
///
/// Query-параметры подтверждены живыми запросами 24.11.2026: выдача каждого варианта
/// сравнивалась по первым id с базовой `filter/0`:
/// * `sort` — 0 «свежие обновления» (значение по умолчанию), 1 «по оценке», 2 «по году»,
///   3 «по популярности»; значения вне 0…3 сервер игнорирует;
/// * `genres` — ровно один жанр в нижнем регистре (`genres=драма`); неизвестный жанр даёт
///   пустую выдачу. Строка с запятой (`жанр1,жанр2`) матчится как подстрока канонического
///   перечня жанров, то есть зависит от порядка и соседства: `триллер,экшен` → 25 релизов,
///   `экшен,триллер` → 0. Поэтому экран отправляет максимум один жанр;
/// * `year` — один год (`year=2020` → только релизы 2020 года); `start_year`/`end_year`
///   в query игнорируются (работают только в POST-теле).
///
/// Дополнительно в query работают `status` (1 «Вышел», 2 «Выходит», 3 «Анонс»),
/// `category` (0 «Не известно», 1 «Сериал», 2 «Фильм», 3 «OVA», 6 «Спешл»), `season` (0…4),
/// `country`, `studio`, `source` (строкой) — в этом экране не используются. Не работают
/// в query: `types`, `age_ratings`, `episodes_from`/`episodes_to`, `is_adult`, `genres_mode`.
///
/// Вызов из клиента: `APIClient.catalog(page:)` уже ходит в `GET filter/{page}` путём
/// `"filter/\(max(page - 1, 0))"`; расширение на его основе добавляет query:
/// `URLComponents(url:resolvingAgainstBaseURL:)` + `components.queryItems = filter.queryItems`.
/// Пример: `GET https://api-s.anixsekai.com/filter/0?sort=1&genres=драма&year=2020`.
///
/// Альтернатива, которую использует Android-приложение, — POST `filter/{page}` с JSON-телом
/// (нужен, когда жанров несколько, потому что там `genres` — массив с честным AND):
/// `{"sort": 1, "genres": ["драма"], "status_id": 2, "category_id": 1, "season": 3,
/// "start_year": 2020, "end_year": 2022, "country": "Япония", "studio": "MAPPA"}`.
/// Query-параметры POST молча игнорирует, поэтому `queryItems` к нему не подмешивать.
struct ReleaseFilter: Equatable {
    /// Значения query-параметра `sort` (совпадают с `FilterSortType` из SDK Anixart).
    enum Sort: Int, CaseIterable, Identifiable {
        case dateUpdate = 0
        case grade = 1
        case year = 2
        case popular = 3

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .dateUpdate: return "Новые"
            case .grade: return "Оценка"
            case .year: return "Год"
            case .popular: return "Топ"
            }
        }
    }

    var sort: Sort = .dateUpdate

    /// Не больше одного жанра: сервер сопоставляет строку жанров как подстроку (см. выше).
    var genres: [String] = []

    var year: Int?

    /// Готовые query-параметры для `GET filter/{page}`. Фильтр по умолчанию даёт пустой
    /// список — то есть URL без query, ровно как сейчас у `APIClient.catalog(page:)`.
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if sort != .dateUpdate {
            items.append(URLQueryItem(name: "sort", value: String(sort.rawValue)))
        }
        if !genres.isEmpty {
            items.append(URLQueryItem(name: "genres", value: genres.joined(separator: ",")))
        }
        if let year {
            items.append(URLQueryItem(name: "year", value: String(year)))
        }
        return items
    }
}

// MARK: - Модель экрана

@MainActor
final class SearchFiltersViewModel: ObservableObject {
    /// Справочника жанров в API нет (в релизе `genres` — просто строка), поэтому список
    /// ограничен жанрами фикстуры `analysis/fixtures/filter_1.json`. Каждый проверен живым
    /// запросом `filter/0?genres=<жанр>`: выдача непустая и содержит этот жанр.
    let availableGenres = [
        "антропоморфизм", "боевые искусства", "взрослые персонажи", "гарем", "детектив", "драма",
        "забота о детях", "злодейка", "исторический", "исэкай", "комедия", "меха",
        "организованная преступность", "приключения", "путешествие во времени", "реинкарнация",
        "романтика", "сверхъестественное", "спорт", "сёдзё", "сёнен", "тайна", "фэнтези", "школа",
        "экшен"
    ]

    /// Справочника годов в API тоже нет: `year` принимает один год (живьём проверены 1980…2035).
    /// В UI показываем разумное окно — от 2027 (анонсы) до 1990.
    let availableYears = Array((1990...2027).reversed())

    /// Черновик фильтра: экран меняет его только методами ниже, родитель получает по «Применить».
    @Published private(set) var selected: ReleaseFilter

    init(filter: ReleaseFilter = ReleaseFilter()) {
        selected = filter
    }

    var isDefault: Bool { selected == ReleaseFilter() }

    func select(sort: ReleaseFilter.Sort) {
        selected.sort = sort
    }

    /// Чипы жанра одиночные: повторное нажатие снимает выбор.
    func toggle(genre: String) {
        selected.genres = selected.genres.contains(genre) ? [] : [genre]
    }

    func clearGenre() {
        selected.genres = []
    }

    /// Год тоже одиночный: `year` — один год, повторное нажатие снимает выбор.
    func select(year: Int) {
        selected.year = selected.year == year ? nil : year
    }

    func clearYear() {
        selected.year = nil
    }

    func reset() {
        selected = ReleaseFilter()
    }
}

// MARK: - Экран

/// Содержимое sheet'а фильтров каталога.
///
/// Вместо `@Binding var filter`: в заглушке `tools/StubSwiftUI/StubKit.swift` `Binding` —
/// обычный класс без `@propertyWrapper`, и `@Binding` в ней не компилируется. Семантика та же:
/// `SearchFiltersView(filter: $filter) { applied in ... }` пишет результат обратно в binding.
struct SearchFiltersView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: SearchFiltersViewModel

    private let filterBinding: Binding<ReleaseFilter>

    /// Вызывается после «Применить»: родитель обновляет каталог и закрывает sheet.
    var onApply: (ReleaseFilter) -> Void

    init(filter: Binding<ReleaseFilter>, onApply: @escaping (ReleaseFilter) -> Void) {
        _model = StateObject(wrappedValue: SearchFiltersViewModel(filter: filter.wrappedValue))
        filterBinding = filter
        self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    sortSection
                    genresSection
                    yearsSection
                }
                .padding(20)
            }

            footer
        }
        .screenBackground()
    }

    // MARK: - Контент

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Фильтры")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Сортировка, жанр и год каталога")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var sortSection: some View {
        section("Сортировка") {
            Picker("Сортировка", selection: sortBinding) {
                ForEach(ReleaseFilter.Sort.allCases) { option in
                    Text(option.title)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var genresSection: some View {
        section("Жанр") {
            LazyVGrid(columns: chipColumns(minimum: 96), alignment: .leading, spacing: 8) {
                FilterChip(title: "Любой", isSelected: model.selected.genres.isEmpty) {
                    model.clearGenre()
                }
                ForEach(model.availableGenres, id: \.self) { genre in
                    FilterChip(title: genre, isSelected: model.selected.genres.contains(genre)) {
                        model.toggle(genre: genre)
                    }
                }
            }
        }
    }

    private var yearsSection: some View {
        section("Год") {
            LazyVGrid(columns: chipColumns(minimum: 64), alignment: .leading, spacing: 8) {
                FilterChip(title: "Любой", isSelected: model.selected.year == nil) {
                    model.clearYear()
                }
                ForEach(model.availableYears, id: \.self) { year in
                    FilterChip(title: String(year), isSelected: model.selected.year == year) {
                        model.select(year: year)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Сбросить") {
                model.reset()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .buttonStyle(.plain)
            .disabled(model.isDefault)

            Button("Применить") {
                apply()
            }
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    // MARK: - Действия

    private func apply() {
        filterBinding.wrappedValue = model.selected
        onApply(model.selected)
        dismiss()
    }

    // MARK: - Вспомогательное

    private var sortBinding: Binding<ReleaseFilter.Sort> {
        Binding(
            get: { model.selected.sort },
            set: { model.select(sort: $0) }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            content()
        }
    }

    private func chipColumns(minimum: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: 8)]
    }
}

// MARK: - Чип

/// Кнопка-чип одного значения фильтра: выбран/не выбран.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(isSelected ? Theme.accentSoft : Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? Theme.accent : Theme.separator, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
