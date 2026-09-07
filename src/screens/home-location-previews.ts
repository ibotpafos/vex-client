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

export function locationCarouselItemLayout(cardWidth: number, itemGap: number, index: number) {
  const length = cardWidth + itemGap;
  return { index, length, offset: length * index };
}

export function stableHomeLocationPreviews(
  previous: VpnLocation[],
  availableLocations: VpnLocation[],
  selectedLocation?: VpnLocation | null,
): VpnLocation[] {
  const next = homeLocationPreviews(availableLocations, selectedLocation);
  if (previous.length !== next.length) {
    return next;
  }
  return previous.every((location, index) => sameHomeLocationCard(location, next[index]))
    ? previous
    : next;
}

function sameHomeLocationCard(left: VpnLocation, right?: VpnLocation): boolean {
  if (!right) {
    return false;
  }
  return left.id === right.id
    && left.countryCode === right.countryCode
    && left.city === right.city
    && left.displayName === right.displayName
    && left.flagEmoji === right.flagEmoji
    && left.availability === right.availability
    && left.priority === right.priority
    && left.status === right.status
    && left.healthyNodes === right.healthyNodes
    && left.endpoint === right.endpoint
    && left.capabilities.length === right.capabilities.length
    && left.capabilities.every((capability, index) => capability === right.capabilities[index]);
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
