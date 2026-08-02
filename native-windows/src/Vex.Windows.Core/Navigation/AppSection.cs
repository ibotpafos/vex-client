using System.Collections.ObjectModel;

namespace Vex.Windows.Core.Navigation;

public enum AppSection
{
    Home,
    Account,
    Support,
    Settings,
}

public sealed record AppSectionDescriptor(
    AppSection Id,
    string Title,
    string Glyph);

public static class AppSectionCatalog
{
    public static IReadOnlyList<AppSectionDescriptor> All { get; } =
        new ReadOnlyCollection<AppSectionDescriptor>(
        [
            new(AppSection.Home, "Главная", "\uE80F"),
            new(AppSection.Account, "Аккаунт", "\uE77B"),
            new(AppSection.Support, "Поддержка", "\uE8BD"),
            new(AppSection.Settings, "Настройки", "\uE713"),
        ]);
}
