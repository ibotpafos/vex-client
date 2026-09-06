import type { VpnLocation } from '../api/vexApi';
import countries from 'i18n-iso-countries';
import englishCountryNames from 'i18n-iso-countries/langs/en.json';
import russianCountryNames from 'i18n-iso-countries/langs/ru.json';

countries.registerLocale(englishCountryNames);
countries.registerLocale(russianCountryNames);

export function homeLocationPreviews(
  availableLocations: VpnLocation[],
  selectedLocation?: VpnLocation | null,
): VpnLocation[] {
  const orderedLocations = selectedLocation
    ? [
      selectedLocation,
      ...availableLocations.filter((location) => location.id !== selectedLocation.id),
    ]
    : availableLocations;
  const visibleCountries = new Set<string>();
  return orderedLocations.filter((location) => {
    const countryCode = location.countryCode.trim().toUpperCase();
    if (visibleCountries.has(countryCode)) {
      return false;
    }
    visibleCountries.add(countryCode);
    return true;
  });
}

export function homeLocationCardLabel(location: VpnLocation): string {
  const countryCode = location.countryCode.trim().toUpperCase();
  if (countryCode) {
    const countryName = countries.getName(countryCode, 'ru');
    if (countryName) {
      return countryName;
    }
  }
  return location.displayName || location.city || countryCode;
}

export function serverLocationTechnicalLabel(location: VpnLocation): string | null {
  const countryCode = location.countryCode.trim().toUpperCase();
  const candidate = (location.displayName || location.city).trim();
  if (!candidate) {
    return null;
  }
  const genericCountryNames = [
    countries.getName(countryCode, 'ru'),
    countries.getName(countryCode, 'en'),
    countryCode,
  ].filter((value): value is string => Boolean(value));
  const normalizedCandidate = candidate.toLocaleLowerCase('ru');
  return genericCountryNames.some((name) => name.toLocaleLowerCase('ru') === normalizedCandidate)
    ? null
    : candidate;
}
