// StubKit.swift
// Minimal fake SwiftUI / Combine / AVKit / WebKit / Security for Linux typecheck.
// Цель — проверять НАШ код, а не изобразить SwiftUI. Всё, чего тут нет, — шум заглушки.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Result builders

@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C: View>(_ c: C) -> C { c }
    public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View>(_ c0: C0, _ c1: C1, _ c2: C2) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> StubEmptyView { StubEmptyView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View, C9: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> StubEmptyView { StubEmptyView() }
    public static func buildOptional<C: View>(_ c: C?) -> C? { c }
    public static func buildEither<C: View>(first: C) -> StubEmptyView { StubEmptyView() }
    public static func buildEither<C: View>(second: C) -> StubEmptyView { StubEmptyView() }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

@resultBuilder
public struct SceneBuilder {
    public static func buildBlock<C: Scene>(_ c: C) -> C { c }
}

// MARK: - Core View

@MainActor
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Self.Body { get }
}

public struct StubEmptyView: View {
    public nonisolated init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// В SwiftUI `EmptyView` — отдельный пустой тип (часто используется в тернарниках и `if`).
public struct EmptyView: View {
    public nonisolated init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// Минимальная заглушка `Link` (открывает URL).
public struct Link<Label: View>: View {
    public nonisolated init(destination: URL, @ViewBuilder label: () -> Label) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension Link where Label == Text {
    public init(_ titleKey: LocalizedStringKey, destination: URL) {}
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct AnyStubView: View {
    public nonisolated init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Geometry / layout primitives

public struct CGFloat_ {}
public struct Alignment {
    public static let center = Alignment()
    public static let leading = Alignment()
    public static let trailing = Alignment()
    public static let top = Alignment()
    public static let bottom = Alignment()
    public static let topLeading = Alignment()
    public static let bottomLeading = Alignment()
    public static let topTrailing = Alignment()
    public static let bottomTrailing = Alignment()
}
public struct HorizontalAlignment {
    public static let leading = HorizontalAlignment()
    public static let center = HorizontalAlignment()
    public static let trailing = HorizontalAlignment()
}
public struct VerticalAlignment {
    public static let top = VerticalAlignment()
    public static let center = VerticalAlignment()
    public static let bottom = VerticalAlignment()
}
public struct Edge {
    public struct Set {
        public static let top = Edge.Set()
        public static let bottom = Edge.Set()
        public static let leading = Edge.Set()
        public static let trailing = Edge.Set()
        public static let horizontal = Edge.Set()
        public static let vertical = Edge.Set()
        public static let all = Edge.Set()
    }
}
public struct Axis {
    public struct Set {
        public static let horizontal = Axis.Set()
        public static let vertical = Axis.Set()
        public static let all = Axis.Set()
    }
}
public struct SafeAreaRegions {
    public static let all = SafeAreaRegions()
    public static let container = SafeAreaRegions()
    public static let keyboard = SafeAreaRegions()
}
public struct FillStyle {
    public init(eoFill: Bool = false, antialiased: Bool = true) {}
}
public enum ContentMode { case fit, fill }
public enum TextAlignment { case leading, center, trailing }
public enum ColorScheme { case light, dark }
public struct ContentSizeCategory_ {}

// MARK: - Shape / Style protocols

@MainActor
public protocol Shape: View {}

public protocol ShapeStyle {}

public extension ShapeStyle where Self == Color {
    static var white: Color { Color.white }
    static var black: Color { Color.black }
    static var clear: Color { Color.clear }
    static var gray: Color { Color.gray }
    static var red: Color { Color.red }
    static var primary: Color { Color.primary }
    static var secondary: Color { Color.secondary }
    static var accentColor: Color { Color.accentColor }
}

public struct Rectangle: Shape {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct Circle: Shape {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct Capsule: Shape {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct RoundedRectangle: Shape {
    public enum Style { case circular, continuous }
    public init(cornerRadius: CGFloat, style: Style = .circular) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct LinearGradient: View {
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {}
    public init(gradient: Any, startPoint: UnitPoint, endPoint: UnitPoint) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct UnitPoint {
    public static let center = UnitPoint()
    public static let top = UnitPoint()
    public static let bottom = UnitPoint()
    public static let topLeading = UnitPoint()
    public static let topTrailing = UnitPoint()
    public static let bottomLeading = UnitPoint()
    public static let bottomTrailing = UnitPoint()
    public static let leading = UnitPoint()
    public static let trailing = UnitPoint()
}

// MARK: - Color

public struct Color: ShapeStyle {
    public nonisolated init() {}
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public init(_ colorSpace: Color.RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public init(white: Double, opacity: Double = 1) {}
    public enum RGBColorSpace { case sRGB, sRGBLinear, displayP3 }
    public static let white = Color()
    public static let black = Color()
    public static let clear = Color()
    public static let gray = Color()
    public static let red = Color()
    public static let blue = Color()
    public static let green = Color()
    public static let primary = Color()
    public static let secondary = Color()
    public static let accentColor = Color()
    public func opacity(_ value: Double) -> Color { self }
}

// Конформность в extension: не переносит MainActor-изоляцию протокола View на тип.
extension Color: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Font

public struct Font {
    public struct Weight {
        public static let ultraLight = Weight()
        public static let thin = Weight()
        public static let light = Weight()
        public static let regular = Weight()
        public static let medium = Weight()
        public static let semibold = Weight()
        public static let bold = Weight()
        public static let heavy = Weight()
        public static let black = Weight()
    }
    public struct Design {
        public static let `default` = Design()
        public static let rounded = Design()
        public static let monospaced = Design()
        public static let serif = Design()
    }
    public static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font { Font() }
    public static let largeTitle = Font()
    public static let title = Font()
    public static let title2 = Font()
    public static let title3 = Font()
    public static let headline = Font()
    public static let subheadline = Font()
    public static let body = Font()
    public static let callout = Font()
    public static let footnote = Font()
    public static let caption = Font()
    public static let caption2 = Font()
    public func weight(_ weight: Font.Weight) -> Font { self }
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospacedDigit() -> Font { self }
    public func monospaced() -> Font { self }
}

// MARK: - Text / Label / Image

public struct LocalizedStringKey: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Equatable {
    public var key: String
    public init(_ value: String) { key = value }
    public init(stringLiteral value: String) { key = value }
    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.result }
    public struct StringInterpolation: StringInterpolationProtocol {
        public var result = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { result += literal }
        public mutating func appendInterpolation<T>(_ value: T) { result += String(describing: value) }
    }
}

public struct Text: View {
    public init(_ key: LocalizedStringKey) {}
    public init<S: StringProtocol>(_ content: S) {}
    public init(verbatim: String) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct Image: View {
    public init(systemName: String) {}
    public init(_ name: String) {}
    public func resizable(capInsets: EdgeInsets_ = EdgeInsets_(), resizingMode: ResizingMode = .stretch) -> Image { self }
    public enum ResizingMode { case tile, stretch }
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct EdgeInsets_ { public init() {} }

public struct Label: View {
    public init(_ titleKey: LocalizedStringKey, systemImage: String) {}
    public init<S: StringProtocol>(_ title: S, systemImage: String) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Controls

public struct ButtonStyle_ {}

public struct Button<Label: View>: View {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
    public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) where Label == Text {
        self.init(action: action) { Text(title) }
    }
    public init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) where Label == Text {
        self.init(action: action) { Text(titleKey) }
    }
}

public struct Menu<Label: View, Content: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct TextField: View {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct SecureField: View {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct TextInputAutocapitalization {
    public static let never = TextInputAutocapitalization()
    public static let words = TextInputAutocapitalization()
    public static let sentences = TextInputAutocapitalization()
    public static let characters = TextInputAutocapitalization()
}
public struct UITextContentType {
    public static let username = UITextContentType()
    public static let password = UITextContentType()
    public static let name = UITextContentType()
}
public struct SubmitLabel {
    public static let done = SubmitLabel()
    public static let go = SubmitLabel()
}
public struct SearchFieldPlacement {
    public static let automatic = SearchFieldPlacement()
    public static let navigationBarDrawer = SearchFieldPlacement()
}

public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    public init() where Label == EmptyStub, CurrentValueLabel == EmptyStub {}
    public init(value: Double, total: Double = 1.0) where Label == EmptyStub, CurrentValueLabel == EmptyStub {}
    public init(_ label: Text) where Label == Text, CurrentValueLabel == EmptyStub {}
    public init(value: Double, total: Double = 1.0, @ViewBuilder label: () -> Label) where CurrentValueLabel == EmptyStub {}
    public init(value: Double, total: Double = 1.0, @ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct EmptyStub: View {
    public nonisolated init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public struct Divider: View {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct Spacer: View {
    public init(minLength: CGFloat? = nil) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Containers

public struct VStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct HStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct Group<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct ScrollView<Content: View>: View {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct LazyVStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: [Any] = [], @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct LazyHStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: [Any] = [], @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct GridItem {
    public struct Size {
        public static func flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity) -> Size { Size() }
        public static func fixed(_ size: CGFloat) -> Size { Size() }
        public static func adaptive(minimum: CGFloat, maximum: CGFloat = .infinity) -> Size { Size() }
    }
    public init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
}
public struct LazyVGrid<Content: View>: View {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: [Any] = [], @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Navigation

public struct NavigationStack<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct NavigationView<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct NavigationLink<Label: View, Destination: View>: View {
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {}
    public init(destination: Destination, @ViewBuilder label: () -> Label) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct NavigationBarItemTitleDisplayMode {
    public static let automatic = NavigationBarItemTitleDisplayMode()
    public static let inline = NavigationBarItemTitleDisplayMode()
    public static let large = NavigationBarItemTitleDisplayMode()
}
public struct ToolbarItemPlacement {
    public static let automatic = ToolbarItemPlacement()
    public static let navigationBarLeading = ToolbarItemPlacement()
    public static let navigationBarTrailing = ToolbarItemPlacement()
    public static let principal = ToolbarItemPlacement()
    public static let bottomBar = ToolbarItemPlacement()
}
public struct ToolbarItem<Content: View>: View {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct ToolbarItemGroup<Content: View>: View {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public struct TabView<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public init(selection: Binding<Int>, @ViewBuilder content: () -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}
public protocol ButtonStyle {}
public struct PlainButtonStyle: ButtonStyle {
    public init() {}
}
public struct BorderedProminentButtonStyle: ButtonStyle {
    public init() {}
}
public struct BorderedButtonStyle: ButtonStyle {
    public init() {}
}
public extension ButtonStyle where Self == PlainButtonStyle {
    static var plain: PlainButtonStyle { PlainButtonStyle() }
}
public extension ButtonStyle where Self == BorderedProminentButtonStyle {
    static var borderedProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() }
}
public extension ButtonStyle where Self == BorderedButtonStyle {
    static var bordered: BorderedButtonStyle { BorderedButtonStyle() }
}

// MARK: - Async image

public enum AsyncImagePhase {
    case empty
    case success(Image)
    case failure(Error)
}
public struct AsyncImage<Content: View>: View {
    public init(url: URL?, scale: CGFloat = 1, transaction: Any = 0, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {}
    public init(url: URL?, scale: CGFloat = 1) where Content == Image {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Combine-ish

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }
}

public final class Binding<Value> {
    public var wrappedValue: Value
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { wrappedValue = get() }
    public init(get: @escaping () -> Value) { wrappedValue = get() }
    public subscript<M>(dynamicMember keyPath: WritableKeyPath<Value, M>) -> Binding<M> {
        Binding<M>(get: { self.wrappedValue[keyPath: keyPath] }, set: { self.wrappedValue[keyPath: keyPath] = $0 })
    }
}

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject> {
    @dynamicMemberLookup
    public struct Wrapper {
        public init() {}
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            Binding<Subject>(get: { fatalError() }, set: { _ in })
        }
    }
    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public var wrappedValue: ObjectType
    @MainActor public var projectedValue: ObservedObject<ObjectType>.Wrapper { Wrapper() }
}

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject> {
    public init(wrappedValue: @autoclosure @escaping () -> ObjectType) { self.wrappedValue = wrappedValue() }
    private var storage: ObjectType
    public var wrappedValue: ObjectType {
        get { storage }
        set { storage = newValue }
    }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject<ObjectType>.Wrapper() }
}

@propertyWrapper
public struct ObservedObjectProperty<ObjectType: ObservableObject> {
    public var wrappedValue: ObjectType
    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject<ObjectType>.Wrapper() }
}

@propertyWrapper
public struct State<Value> {
    private final class Box {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let box: Box
    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public init(initialValue: Value) { box = Box(initialValue) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        Binding<Value>(get: { self.box.value }, set: { self.box.value = $0 })
    }
}

@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject> {
    public init() {}
    public var wrappedValue: ObjectType { fatalError() }
}

public struct DismissAction {
    public init() {}
    public func callAsFunction() {}
}

public struct EnvironmentValues {
    public init() {}
    public var dismiss: DismissAction { DismissAction() }
    public var isPresented_: Bool { false }
}

@propertyWrapper
public struct Environment<Value> {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}

// MARK: - View modifiers

@MainActor
public extension View {
    func font(_ font: Font?) -> some View { AnyStubView() }
    func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { AnyStubView() }
    func foregroundColor(_ color: Color?) -> some View { AnyStubView() }
    func padding(_ length: CGFloat) -> some View { AnyStubView() }
    func padding(_ edges: Edge.Set, _ length: CGFloat? = nil) -> some View { AnyStubView() }
    func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { AnyStubView() }
    func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
               minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
               alignment: Alignment = .center) -> some View { AnyStubView() }
    func frame(maxWidth: CGFloat?, maxHeight: CGFloat?) -> some View { AnyStubView() }
    func clipped() -> some View { AnyStubView() }
    func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { AnyStubView() }
    func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View { AnyStubView() }
    func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> some View { AnyStubView() }
    func background<V: View>(_ view: V, alignment: Alignment = .center) -> some View { AnyStubView() }
    func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View { AnyStubView() }
    func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View { AnyStubView() }
    func aspectRatio(contentMode: ContentMode) -> some View { AnyStubView() }
    func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { AnyStubView() }
    func lineLimit(_ number: Int?) -> some View { AnyStubView() }
    func multilineTextAlignment(_ alignment: TextAlignment) -> some View { AnyStubView() }
    func fixedSize(horizontal: Bool = false, vertical: Bool = false) -> some View { AnyStubView() }
    func opacity(_ opacity: Double) -> some View { AnyStubView() }
    func disabled(_ disabled: Bool) -> some View { AnyStubView() }
    func contentShape<S: Shape>(_ shape: S) -> some View { AnyStubView() }
    func buttonStyle<S: ButtonStyle>(_ style: S) -> some View { AnyStubView() }
    func tint(_ tint: Color?) -> some View { AnyStubView() }
    func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View { AnyStubView() }
    func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { AnyStubView() }
    func navigationTitle<S: StringProtocol>(_ title: S) -> some View { AnyStubView() }
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItemTitleDisplayMode) -> some View { AnyStubView() }
    func searchable<S: StringProtocol>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: S) -> some View { AnyStubView() }
    func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil) -> some View { AnyStubView() }
    func textInputAutocapitalization(_ style: TextInputAutocapitalization?) -> some View { AnyStubView() }
    func autocorrectionDisabled(_ disable: Bool = true) -> some View { AnyStubView() }
    func textContentType(_ type: UITextContentType?) -> some View { AnyStubView() }
    func toolbar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { AnyStubView() }
    func toolbar<Content: View>(_ position: Int, @ViewBuilder _ content: () -> Content) -> some View { AnyStubView() }
    func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View { AnyStubView() }
    func task(priority: Any = 0, _ action: @escaping @Sendable () async -> Void) -> some View { AnyStubView() }
    func task<ID: Equatable>(id: ID, priority: Any = 0, _ action: @escaping @Sendable () async -> Void) -> some View { AnyStubView() }
    func refreshable(action: @escaping @Sendable () async -> Void) -> some View { AnyStubView() }
    func onAppear(perform action: (() -> Void)? = nil) -> some View { AnyStubView() }
    func onDisappear(perform action: (() -> Void)? = nil) -> some View { AnyStubView() }
    func fullScreenCover<Content: View, Item: Identifiable>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View { AnyStubView() }
    func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View { AnyStubView() }
    func environmentObject<T: ObservableObject>(_ object: T) -> some View { AnyStubView() }
    func accentColor(_ color: Color?) -> some View { AnyStubView() }
    func bold() -> some View { AnyStubView() }
    func hidden() -> some View { AnyStubView() }
    func scaledToFit() -> some View { AnyStubView() }
}

// MARK: - Deep links (RootView: onOpenURL / onContinueUserActivity)

@MainActor
public extension View {
    func onOpenURL(perform action: @escaping (URL) -> Void) -> some View { AnyStubView() }
    func onContinueUserActivity(_ activityType: String,
                                perform action: @escaping (NSUserActivity) -> Void) -> some View { AnyStubView() }
}

/// В Foundation константа есть на Apple-платформах, на Linux — нет.
public let NSUserActivityTypeBrowsingWeb: String = "com.apple.NSUserActivityTypeBrowsingWeb"

@MainActor
public extension Shape {
    func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { AnyStubView() }
    func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle) -> some View { AnyStubView() }
    func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View { AnyStubView() }
}
public struct StrokeStyle {
    public init(lineWidth: CGFloat = 1, lineCap: Int = 0, lineJoin: Int = 0) {}
}

// MARK: - App / Scene

@MainActor
public protocol Scene {
}
public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
}
@MainActor
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Self.Body { get }
}

public extension App {
    static func main() {}
}

// MARK: - AVKit

public class AVPlayer {
    public init(url: URL) {}
    public func play() {}
    public func pause() {}
}
public struct VideoPlayer: View {
    public init(player: AVPlayer?) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - UIKit / WebKit

public class UIColor {
    public init() {}
    public static let black = UIColor()
    public static let white = UIColor()
    public static let clear = UIColor()
}
public class UIScrollView {
    public init() {}
    public var isScrollEnabled: Bool = true
    public var backgroundColor: UIColor?
}
public class UIView {
    public init() {}
    public init(frame: CGRect) {}
    public var backgroundColor: UIColor?
    public var isOpaque: Bool = true
    public var scrollView: UIScrollView = UIScrollView()
    public var customUserAgent: String?
}
public struct WKAudiovisualMediaTypes: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let audio = WKAudiovisualMediaTypes(rawValue: 1)
    public static let video = WKAudiovisualMediaTypes(rawValue: 2)
    public static let all = WKAudiovisualMediaTypes(rawValue: 3)
}
public class WKWebpagePreferences {
    public init() {}
    public var allowsContentJavaScript: Bool = true
}
public class WKWebViewConfiguration {
    public init() {}
    public var allowsInlineMediaPlayback: Bool = false
    public var allowsPictureInPictureMediaPlayback: Bool = false
    public var mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = []
    public var defaultWebpagePreferences: WKWebpagePreferences = WKWebpagePreferences()
}
public class WKWebView: UIView {
    public init(frame: CGRect, configuration: WKWebViewConfiguration) { super.init() }
    public var allowsBackForwardNavigationGestures: Bool = false
    public func load(_ request: URLRequest) -> WKNavigation? { nil }
    public func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }
}

public class WKNavigation {}
public struct UIViewRepresentableContext<Representable> {
    public init() {}
}
@MainActor
public protocol UIViewRepresentable: View {
    associatedtype UIViewType: UIView
    typealias Context = UIViewRepresentableContext<Self>
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ uiView: UIViewType, context: Context)
}

public extension UIViewRepresentable {
    var body: Never { fatalError() }
}

// MARK: - Security (только константы и сигнатуры)

public typealias OSStatus = Int32
public typealias CFTypeRef = Any
public typealias CFDictionary = [String: Any]

public let kSecClass: String = "kSecClass"
public let kSecClassGenericPassword: String = "kSecClassGenericPassword"
public let kSecAttrService: String = "kSecAttrService"
public let kSecAttrAccount: String = "kSecAttrAccount"
public let kSecValueData: String = "kSecValueData"
public let kSecAttrAccessible: String = "kSecAttrAccessible"
public let kSecAttrAccessibleAfterFirstUnlock: String = "kSecAttrAccessibleAfterFirstUnlock"
public let kSecReturnData: String = "kSecReturnData"
public let kSecMatchLimit: String = "kSecMatchLimit"
public let kSecMatchLimitOne: String = "kSecMatchLimitOne"
public let errSecSuccess: OSStatus = 0

public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }

// MARK: - Заглушки, добавленные для новых экранов (link, onboarding, settings)

public class NSUserActivity {
    public var webpageURL: URL?
    public var activityType: String = ""
    public init(activityType: String) {}
}

public struct ButtonRole {
    public static let cancel = ButtonRole()
    public static let destructive = ButtonRole()
}

public struct PageIndexDisplayMode {
    public static let automatic = PageIndexDisplayMode()
    public static let always = PageIndexDisplayMode()
    public static let never = PageIndexDisplayMode()
}

public struct TabViewStyleStub {
    public static let automatic = TabViewStyleStub()
    public static let page = TabViewStyleStub()
    public static func page(indexDisplayMode: PageIndexDisplayMode) -> TabViewStyleStub { TabViewStyleStub() }
}

public struct PageIndexBackgroundDisplayMode {
    public static let automatic = PageIndexBackgroundDisplayMode()
    public static let always = PageIndexBackgroundDisplayMode()
    public static let never = PageIndexBackgroundDisplayMode()
}

public struct PageIndexViewStyleStub {
    public static func page(backgroundDisplayMode: PageIndexBackgroundDisplayMode) -> PageIndexViewStyleStub { PageIndexViewStyleStub() }
}

public func withAnimation<Result>(_ animation: Animation? = nil, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping () -> Void) {}
}

extension View {
    public func tabViewStyle(_ style: TabViewStyleStub) -> some View { AnyStubView() }
    public func indexViewStyle(_ style: PageIndexViewStyleStub) -> some View { AnyStubView() }
    public func tag<V: Hashable>(_ value: V) -> some View { AnyStubView() }
    public func accessibilityLabel(_ label: LocalizedStringKey) -> some View { AnyStubView() }
    public func accessibilityLabel(_ label: String) -> some View { AnyStubView() }
    /// Идентификатор для UI-тестов: на стенде no-op, на iOS — настоящий модификатор.
    public func accessibilityIdentifier(_ identifier: String) -> some View { AnyStubView() }
    public func alert<A: View>(_ titleKey: LocalizedStringKey,
                               isPresented: Binding<Bool>,
                               @ViewBuilder actions: () -> A) -> some View { AnyStubView() }
    public func alert<A: View, M: View>(_ titleKey: LocalizedStringKey,
                                        isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A,
                                        @ViewBuilder message: () -> M) -> some View { AnyStubView() }
}

// MARK: - UIKit / анимации (для ImageCache и онбординга)

public class UIImage {
    public init?(data: Data) {}
}

extension Image {
    public init(uiImage: UIImage) {}
}

public struct Animation {
    public static func easeInOut(duration: Double) -> Animation { Animation() }
    public static func easeIn(duration: Double) -> Animation { Animation() }
    public static func easeOut(duration: Double) -> Animation { Animation() }
    public static func linear(duration: Double) -> Animation { Animation() }
    public static let easeInOut = Animation()
}

// MARK: - Picker / sheet(item:) для сегментированного поиска

public struct SegmentedPickerStyle {
    public static let segmented = SegmentedPickerStyle()
    public static let automatic = SegmentedPickerStyle()
}

extension View {
    public func pickerStyle(_ style: SegmentedPickerStyle) -> some View { AnyStubView() }
    public func sheet<Content: View, Item: Identifiable>(item: Binding<Item?>,
                                                         onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Content) -> some View { AnyStubView() }
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    public init(_ titleKey: LocalizedStringKey,
                selection: Binding<SelectionValue>,
                @ViewBuilder content: () -> Content) where Label == Text {}
    public init(selection: Binding<SelectionValue>,
                @ViewBuilder content: () -> Content) where Label == Text {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Геометрия и анимации (для скелетонов)

public struct CGSize {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
    public static let zero = CGSize(width: 0, height: 0)
}

public struct CGPoint {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
}

public struct CGRect {
    public var origin: CGPoint
    public var size: CGSize
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public static let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
}

public struct GeometryProxy {
    public var size: CGSize { CGSize(width: 0, height: 0) }
    public func frame(in space: CoordinateSpace) -> CGRect { CGRect.zero }
}

public struct CoordinateSpace {
    public static let global = CoordinateSpace()
    public static let local = CoordinateSpace()
    public static let named = CoordinateSpace()
}

public struct GeometryReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension Animation {
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
    public func speed(_ speed: Double) -> Animation { self }
    public func delay(_ delay: Double) -> Animation { self }
}

extension View {
    public func mask<Mask: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> Mask) -> some View { AnyStubView() }
    public func mask<Mask: View>(_ mask: Mask) -> some View { AnyStubView() }
}

extension View {
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { AnyStubView() }
    public func offset(_ offset: CGSize) -> some View { AnyStubView() }
    public func rotationEffect(_ angle: Double) -> some View { AnyStubView() }
    public func scaleEffect(_ scale: CGFloat) -> some View { AnyStubView() }
}

// MARK: - ShareLink (iOS 16)

public struct ShareLink<Content: View>: View {
    public init(item: String, @ViewBuilder label: () -> Content) {}
    public init(item: URL, @ViewBuilder label: () -> Content) {}
    public init(_ titleKey: LocalizedStringKey, item: String) where Content == Text {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}

// MARK: - Заглушка экрана плеера
// Файлы Features/Player/PlayerView.swift и NativePlayerView.swift исключены из
// стаб-проверки (AVFoundation/PiP заглушками не моделируются — их проверяет xcodebuild).
// Но ReleaseView на них ссылается, поэтому в блобе объявлен минимальный интерфейс.

public struct PlayerView: View {
    init(target: PlaybackTarget,
         releaseId: Int? = nil,
         sourceId: Int? = nil,
         position: Int? = nil,
         typeId: Int? = nil,
         onClose: (() -> Void)? = nil) {}
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError() }
}


// MARK: - Заглушка DownloadManager
// Сам файл исключён из стаб-проверки (AVFoundation), но DownloadsView на него ссылается.

public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()
    var items: [DownloadItem] = []
    private init() {}
    public func beginDownload(releaseId: Int,
                              sourceId: Int,
                              position: Int,
                              title: String,
                              url: URL) throws {}
    public func cancel(id: String) {}
    public func remove(id: String, deleteFile: Bool = true) {}
    public func isDownloaded(releaseId: Int, sourceId: Int, position: Int) -> Bool { false }
    func item(releaseId: Int, sourceId: Int, position: Int) -> DownloadItem? { nil }
    public func loadPersisted() {}
    public func persist() {}
}
