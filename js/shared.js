const _IS_LOCAL = ['localhost', '127.0.0.1'].includes(window.location.hostname);
const PLUMBER_BASE = _IS_LOCAL
  ? 'http://127.0.0.1:8000'
  : 'https://aetherno-areastat-r-api.hf.space';
const ML_BASE = _IS_LOCAL
  ? 'http://127.0.0.1:8001'
  : 'https://aetherno-areastat-python-api.hf.space';

const DEFAULT_PROFILE_CATEGORIES = [
  'Altersstruktur',
  'Arbeitsmarkt',
  'Wirtschaft',
  'Bildung',
  'Migration',
  'Haushalte'
];

const EXCLUDED_PROFILE_KEYS = [
  'Urban_rural_status',
  'Settlement_class',
  'Density_class',
  'Bezirk',
  'Gemeindename',
  'Bundesland',
  'Bevölkerung'
];

const SEGMENTATION_CONFIG = {
  urban_rural: {
    label_de: 'Urban-Rural',
    label_en: 'Urban-Rural',
    dataKey: 'Urban_rural_status',
    prop: '_ur',
    classes: [
      { key: 'Städtisch', label_de: 'Städtisch', label_en: 'Urban', color: '#0570b0' },
      { key: 'Intermediär', label_de: 'Intermediär', label_en: 'Intermediate', color: '#f07b20' },
      { key: 'Ländlich', label_de: 'Ländlich', label_en: 'Rural', color: '#2ca25f' },
    ]
  },
  settlement: {
    label_de: 'Siedlungsgröße',
    label_en: 'Settlement Size',
    dataKey: 'Settlement_class',
    prop: '_settlement',
    classes: [
      { key: 'Großstadt', label_de: 'Großstadt', label_en: 'Large City', color: '#6b2d8b' },
      { key: 'Kleinstadt', label_de: 'Kleinstadt', label_en: 'Small City', color: '#1d6fa5' },
      { key: 'Marktgemeinde', label_de: 'Marktgemeinde', label_en: 'Market Town', color: '#e07520' },
      { key: 'Dorfgemeinde', label_de: 'Dorfgemeinde', label_en: 'Village', color: '#3d9c57' },
    ]
  },
  density: {
    label_de: 'Bevölkerungsdichte',
    label_en: 'Population Density',
    dataKey: 'Density_class',
    prop: '_density',
    classes: [
      { key: 'Sehr dicht', label_de: 'Sehr dicht', label_en: 'Very Dense', color: '#084594' },
      { key: 'Dicht', label_de: 'Dicht', label_en: 'Dense', color: '#2171b5' },
      { key: 'Mittel', label_de: 'Mittel', label_en: 'Medium', color: '#4393c3' },
      { key: 'Dünn', label_de: 'Dünn', label_en: 'Sparse', color: '#7ec8e3' },
      { key: 'Unbekannt', label_de: 'Unbekannt', label_en: 'Unknown', color: '#cccccc' },
    ]
  },
};

const I18N = {
  en: {
    'app.badge': '◈ PhD Research Proposal',
    'app.title': 'AreaStat AT',
    'app.subtitle': 'Statistik Austria OGD',
    'card.header': '◈ Select Areas',
    'card.bundesland': 'Federal State',
    'card.ebene': 'Level',
    'card.clear': 'Clear',
    'card.reset': 'Reset',
    'legend.urban': 'Urban',
    'legend.inter': 'Intermediate',
    'legend.rural': 'Rural',
    'btn.build': 'Open in AreaStat →',
    'drawer.indicators': 'Indicators ▼',
    'drawer.demographie': 'Demographics ▼',
    'drawer.wirtschaft': 'Economy ▼',
    'dom.altersstruktur': 'Age Structure',
    'dom.migration': 'Migration',
    'dom.haushalte': 'Households',
    'dom.arbeitsmarkt': 'Labour Market',
    'dom.wirtschaft': 'Economy',
    'dom.bildung': 'Education',
    'tab.charts': 'Charts',
    'tab.tables': 'Tables',
    'btn.excel': '⬇ Excel',
    'btn.image': '⬇ Image',
    'btn.typology': 'Run Typology',
    'col.indicator': 'Indicator',
    'col.selected': 'Avg Selected',
    'col.austria': 'Austria Avg',
  },
  de: {
    'app.badge': '◈ Forschungsvorhaben',
    'app.title': 'AreaStat AT',
    'app.subtitle': 'Statistik Austria OGD',
    'card.header': '◈ Gebiete auswählen',
    'card.bundesland': 'Bundesland',
    'card.ebene': 'Ebene',
    'card.clear': 'Löschen',
    'card.reset': 'Zurücksetzen',
    'legend.urban': 'Städtisch',
    'legend.inter': 'Intermediär',
    'legend.rural': 'Ländlich',
    'btn.build': 'In AreaStat öffnen →',
    'drawer.indicators': 'Indikatoren ▼',
    'drawer.demographie': 'Demographie ▼',
    'drawer.wirtschaft': 'Wirtschaft ▼',
    'dom.altersstruktur': 'Altersstruktur',
    'dom.migration': 'Migration',
    'dom.haushalte': 'Haushalte',
    'dom.arbeitsmarkt': 'Arbeitsmarkt',
    'dom.wirtschaft': 'Wirtschaft',
    'dom.bildung': 'Bildung',
    'tab.charts': 'Diagramme',
    'tab.tables': 'Tabellen',
    'btn.excel': '⬇ Excel',
    'btn.image': '⬇ Bild',
    'btn.typology': 'Typologie ausführen',
    'col.indicator': 'Indikator',
    'col.selected': 'Ø Ausgewählt',
    'col.austria': 'Österreich Ø',
  }
};

const LABEL_EN = {
  'Unter 15 Jahre (%)': 'Under 15 years (%)',
  'Über 65 Jahre (%)': 'Over 65 years (%)',
  'Beschäftigungsquote (%)': 'Employment rate (%)',
  'Arbeitslosenquote (%)': 'Unemployment rate (%)',
  'Auspendleranteil (%)': 'Out-commuter share (%)',
  'Beschäftigte': 'Employees',
  'Unternehmen': 'Enterprises',
  'Arbeitsstätten': 'Local units',
  'Sekundarbildung (%)': 'Secondary education (%)',
  'Tertiärbildung (%)': 'Tertiary education (%)',
  'Ausländische Staatsbürger (%)': 'Foreign citizens (%)',
  'Durchschnittliche Haushaltsgröße': 'Avg household size',
  'Privathaushalte': 'Private households',
  'Familien': 'Families',
};

const DOMAIN_EN = {
  'Altersstruktur': 'Age Structure',
  'Arbeitsmarkt': 'Labour Market',
  'Wirtschaft': 'Economy',
  'Bildung': 'Education',
  'Migration': 'Migration',
  'Haushalte': 'Households',
};

const RATE_PER_1000_DOMAIN = 'Wirtschaft';
const RATE_PER_1000_INDICATORS = ['Beschäftigte', 'Unternehmen', 'Arbeitsstätten'];

function t(key) {
  return I18N[currentLang]?.[key] ?? I18N.en[key] ?? key;
}

function tLabel(label) {
  if (currentLang === 'de') return label;
  return LABEL_EN[label] ?? label;
}

function tDomain(domain) {
  if (currentLang === 'de') return domain;
  return DOMAIN_EN[domain] ?? domain;
}

function isRatePer1000Indicator(domain, indicator) {
  return domain === RATE_PER_1000_DOMAIN && RATE_PER_1000_INDICATORS.includes(indicator);
}

function displayIndicatorLabel(domain, indicator) {
  const base = tLabel(indicator);
  if (!isRatePer1000Indicator(domain, indicator)) return base;
  return currentLang === 'de' ? `${base} je 1.000 Einwohner` : `${base} per 1,000 residents`;
}

function formatIndicatorValue(domain, indicator, value) {
  if (typeof value !== 'number' || Number.isNaN(value)) return '–';
  if (indicator.includes('(%)')) return `${value.toFixed(1)}%`;
  if (isRatePer1000Indicator(domain, indicator)) return value.toFixed(1);
  return Number.isInteger(value) ? value.toLocaleString() : value.toFixed(2);
}

function totalPopulationForData(dataMap) {
  return Object.values(dataMap || {}).reduce((sum, zone) => {
    const pop = Number(getScalar(zone?.['Bevölkerung'])) || 0;
    return sum + pop;
  }, 0);
}

function comparableAustriaValue(domain, indicator, rawAustriaValue) {
  if (typeof rawAustriaValue !== 'number') return null;
  if (!isRatePer1000Indicator(domain, indicator)) return rawAustriaValue;
  const population = Number(window.austriaPopulation) || 0;
  return population > 0 ? (rawAustriaValue / population) * 1000 : null;
}

function applyLang() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const key = el.getAttribute('data-i18n');
    el.textContent = t(key);
  });
  const langBtn = document.getElementById('lang-toggle');
  if (langBtn) langBtn.textContent = currentLang === 'en' ? 'DE' : 'EN';
}

function getScalar(v) {
  if (v === null || v === undefined) return v;
  if (Array.isArray(v)) return v[0];
  if (typeof v === 'object') return Object.values(v)[0];
  return v;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
