'use strict';

// Katalog zdrojů Zprávobot.news — vše běží v prohlížeči nad data.json.
// ~540 záznamů → Array#filter/sort stačí, žádné indexování ani framework.
//
// Funkce: filtry (rodina/typ/jazyk/tag), full-text, řezy (platforma/Top N/nedávné),
// řazení, hover preview, detail modal, stav v URL hash, mobilní accordion.

(function () {
  // ---------- i18n ----------
  // Default čeština, ruční přepínač CZ|EN v hlavičce. EN = jen UI shell;
  // obsah (jména, bia, tagy) zůstává v původním jazyce.
  var LANGS = ['cs', 'en'];
  var lang = 'cs';

  var STRINGS = {
    cs: {
      brand_prefix: 'Katalog', title_doc: 'Katalog Zprávobot.news',
      claim: 'Objev své oblíbené zdroje na Mastodonu',
      count_of: 'z', count_sources: 'zdrojů',
      nav_platform: 'Platforma', nav_charts: 'Žebříčky', nav_risers: 'Skokani týdne', nav_new: 'Novinky',
      nav_all: 'Vše', nav_top10_foll: 'Top 10 sledovaných', nav_top10_active: 'Top 10 aktivních',
      nav_top50_foll: 'Top 50 sledovaných', nav_top50_active: 'Top 50 aktivních',
      nav_risers_foll: 'V sledujících', nav_risers_active: 'V aktivitě', nav_recent: 'Nedávno přidané',
      filters_toggle: 'Filtry', search_label: 'Vyhledat', search_ph: 'Jméno nebo handle…',
      sort_label: 'Řadit', sort_name: 'Abecedně', sort_followers: 'Nejvíc sledujících',
      sort_posts: 'Nejaktivnější', sort_added: 'Nejnověji přidané',
      head_topic: 'Oblast', head_type: 'Typ účtu', head_language: 'Jazyk', head_tag: 'Tag',
      tag_ph: 'Filtr podle tagu…', reset: 'Zrušit filtry',
      loading: 'Načítám katalog…', empty_title: 'Žádný zdroj neodpovídá filtrům.',
      empty_hint: 'Zkus uvolnit některý z filtrů.', empty_reset: 'Reset filtrů',
      load_error: 'Nepodařilo se načíst data katalogu.',
      footer_updated: 'Katalog naposledy aktualizován',
      footer_owner: 'Jsi vlastník účtu a chceš jej z katalogu odstranit? Napiš na',
      fam_sport: 'Sport', fam_news: 'Zprávy', fam_culture: 'Kultura', fam_science_tech: 'Věda & technika',
      fam_lifestyle: 'Životní styl', fam_business: 'Byznys', fam_humor: 'Humor', fam_government: 'Stát',
      type_person: 'Osoba', type_media: 'Médium', type_institution: 'Organizace',
      type_institution_formal: 'Instituce', type_institution_filter: 'Instituce/Organizace',
      type_team: 'Tým', type_other: 'Ostatní',
      lang_cs: 'Čeština', lang_sk: 'Slovenčina', lang_en: 'English',
      stat_followers: 'sledujících', stat_posts_week: 'příspěvků/týden', stat_language: 'jazyk',
      modal_sources: 'Původní profily', modal_open: 'Otevřít profil', modal_follow: 'Sledovat',
      modal_follow_title: 'Otevře profil, kde můžeš sledovat ze své Mastodon instance', modal_close: 'Zavřít',
      hover_source: 'Zdroj: ', card_detail: 'Detail ',
      slice_platform: 'Zdroje s platformou ', slice_recent_pre: 'Přidané za posledních ',
      slice_recent_post: ' dní', slice_top_pre: 'Top ', slice_top_post: ' (ostatní filtry kromě oblasti jsou vypnuté)',
      top_phrase_followers: 'podle sledujících', top_phrase_active: 'podle aktivity',
      top_phrase_gain_followers: 'podle nárůstu sledujících', top_phrase_gain_activity: 'podle nárůstu aktivity'
    },
    en: {
      brand_prefix: 'Catalog', title_doc: 'Zprávobot.news Catalog',
      claim: 'Discover your favorite sources on Mastodon',
      count_of: 'of', count_sources: 'sources',
      nav_platform: 'Platform', nav_charts: 'Charts', nav_risers: 'Weekly risers', nav_new: 'New',
      nav_all: 'All', nav_top10_foll: 'Top 10 followed', nav_top10_active: 'Top 10 active',
      nav_top50_foll: 'Top 50 followed', nav_top50_active: 'Top 50 active',
      nav_risers_foll: 'In followers', nav_risers_active: 'In activity', nav_recent: 'Recently added',
      filters_toggle: 'Filters', search_label: 'Search', search_ph: 'Name or handle…',
      sort_label: 'Sort', sort_name: 'Alphabetically', sort_followers: 'Most followers',
      sort_posts: 'Most active', sort_added: 'Recently added',
      head_topic: 'Topic', head_type: 'Account type', head_language: 'Language', head_tag: 'Tag',
      tag_ph: 'Filter by tag…', reset: 'Clear filters',
      loading: 'Loading catalog…', empty_title: 'No source matches the filters.',
      empty_hint: 'Try loosening one of the filters.', empty_reset: 'Reset filters',
      load_error: 'Failed to load catalog data.',
      footer_updated: 'Catalog last updated',
      footer_owner: 'Are you the owner and want it removed from the catalog? Write to',
      fam_sport: 'Sports', fam_news: 'News', fam_culture: 'Culture', fam_science_tech: 'Science & tech',
      fam_lifestyle: 'Lifestyle', fam_business: 'Business', fam_humor: 'Humor', fam_government: 'Government',
      type_person: 'Person', type_media: 'Media', type_institution: 'Organization',
      type_institution_formal: 'Institution', type_institution_filter: 'Institution/Organization',
      type_team: 'Team', type_other: 'Other',
      lang_cs: 'Czech', lang_sk: 'Slovak', lang_en: 'English',
      stat_followers: 'followers', stat_posts_week: 'posts/week', stat_language: 'language',
      modal_sources: 'Original profiles', modal_open: 'Open profile', modal_follow: 'Follow',
      modal_follow_title: 'Opens the profile where you can follow from your own Mastodon instance', modal_close: 'Close',
      hover_source: 'Source: ', card_detail: 'Detail of ',
      slice_platform: 'Sources on ', slice_recent_pre: 'Added in the last ',
      slice_recent_post: ' days', slice_top_pre: 'Top ', slice_top_post: ' (filters except topic are off)',
      top_phrase_followers: 'by followers', top_phrase_active: 'by activity',
      top_phrase_gain_followers: 'by follower growth', top_phrase_gain_activity: 'by activity growth'
    }
  };

  function t(key) {
    var s = STRINGS[lang] && STRINGS[lang][key];
    return s != null ? s : (STRINGS.cs[key] != null ? STRINGS.cs[key] : key);
  }

  // Platform names — značky, nepřekládají se.
  var PLATFORM_LABELS = {
    twitter: 'X', threads: 'Threads', bluesky: 'Bluesky', facebook: 'Facebook',
    instagram: 'Instagram', youtube: 'YouTube', rss: 'RSS'
  };
  function platformLabel(p) { return PLATFORM_LABELS[p] || p; }
  function familyLabel(f) { return t('fam_' + f); }
  function langLabel(l) { return t('lang_' + l); }

  // Typ "institution" se pojmenuje podle oblasti — vláda/kultura „Instituce",
  // jinde „Organizace". Týmy mají vlastní typ.
  var INSTITUTION_FORMAL_FAMILIES = { government: 1, culture: 1 };
  function typeLabel(rec) {
    if (rec.type === 'institution') {
      return INSTITUTION_FORMAL_FAMILIES[rec.family] ? t('type_institution_formal') : t('type_institution');
    }
    return t('type_' + rec.type);
  }

  // Štítek filtru "institution" se přizpůsobí zvolené oblasti (1 oblast → varianta).
  function updateInstitutionFilterLabel() {
    if (!institutionBtnEl) return;
    var label = t('type_institution_filter');
    if (filters.family.size === 1) {
      var fam = filters.family.values().next().value;
      label = INSTITUTION_FORMAL_FAMILIES[fam] ? t('type_institution_formal') : t('type_institution');
    }
    institutionBtnEl.textContent = label;
  }

  // Jazyk z ?lang= (sdílitelné) → localStorage → default 'cs'. Bez detekce prohlížeče.
  function initLang() {
    var fromUrl = new URLSearchParams(location.search).get('lang');
    var stored = null;
    try { stored = localStorage.getItem('zbnw_lang'); } catch (e) { /* ignore */ }
    var pick = fromUrl || stored || 'cs';
    lang = LANGS.indexOf(pick) !== -1 ? pick : 'cs';
    document.documentElement.lang = lang;
  }

  // Přeloží statické prvky ([data-i18n] textContent, [data-i18n-ph] placeholder)
  // + titulek dokumentu. Dynamický obsah (karty/modal) řeší render() přes t().
  function applyI18n() {
    document.title = t('title_doc');
    document.documentElement.lang = lang;
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      el.textContent = t(el.getAttribute('data-i18n'));
    });
    document.querySelectorAll('[data-i18n-ph]').forEach(function (el) {
      el.setAttribute('placeholder', t(el.getAttribute('data-i18n-ph')));
    });
    updateLangSwitchUI();
  }

  function setLang(next) {
    if (LANGS.indexOf(next) === -1 || next === lang) return;
    lang = next;
    try { localStorage.setItem('zbnw_lang', lang); } catch (e) { /* ignore */ }
    // ?lang v query (mimo hash filtrů) — sdílitelné, přežije refresh
    var params = new URLSearchParams(location.search);
    if (lang === 'cs') { params.delete('lang'); } else { params.set('lang', lang); }
    var qs = params.toString();
    history.replaceState(null, '', location.pathname + (qs ? '?' + qs : '') + location.hash);
    applyI18n();
    render();
    renderUpdatedRelative();
  }

  function bindLangSwitch() {
    var sw = document.getElementById('lang-switch');
    if (!sw) return;
    sw.querySelectorAll('button[data-lang]').forEach(function (btn) {
      btn.addEventListener('click', function () { setLang(btn.getAttribute('data-lang')); });
    });
  }

  function updateLangSwitchUI() {
    var sw = document.getElementById('lang-switch');
    if (!sw) return;
    sw.querySelectorAll('button[data-lang]').forEach(function (btn) {
      btn.classList.toggle('is-active', btn.getAttribute('data-lang') === lang);
    });
  }

  // ---------- Konstanty chování ----------
  var RECENT_DAYS = 90;     // okno pro řez "Nedávno přidané"
  var HOVER_DELAY = 400;    // ms než se ukáže hover preview
  var HOVER_GRACE = 200;    // ms tolerance po odjezdu myši
  var TAG_CHIP_COUNT = 10;  // počet nejčastějších tagů jako chips
  var SUGGEST_MAX = 8;      // max položek v autocomplete

  var HOVER_CAPABLE = window.matchMedia &&
    window.matchMedia('(hover: hover) and (pointer: fine)').matches;

  // Žebříčky: metrika řezu → pole záznamu (popisná fráze viz t('top_phrase_*')).
  var TOP_FIELD = {
    followers: 'followers', active: 'posts_week',
    gain_followers: 'followers_delta', gain_activity: 'activity_delta'
  };

  // ---------- Stav ----------
  var records = [];
  var filters = { family: new Set(), type: new Set(), language: new Set(), tag: new Set() };
  var searchQuery = '';
  var sortKey = 'name';
  var slice = { kind: 'all' };   // all | platform:<p> | top:<metric>:<n> | recent

  // ---------- DOM ----------
  var cardsEl, emptyEl, loadingEl, searchEl, resetEl, emptyResetEl,
      visibleCountEl, totalCountEl, sortEl, sliceNoteEl, tabsEl,
      tagInputEl, tagSuggestEl, tagSelectedEl, tagChipsEl,
      sidebarEl, sidebarToggleEl, modalEl, hoverEl, institutionBtnEl;

  var suppressHash = false;   // brání smyčce při programovém zápisu do hash
  var hoverTimer = null, hoverHideTimer = null;
  var pendingAccountId = null;  // z #account=<id> (per-účet sdílecí stub) → otevřít modal

  document.addEventListener('DOMContentLoaded', function () {
    cardsEl        = document.getElementById('cards');
    emptyEl        = document.getElementById('empty-state');
    loadingEl      = document.getElementById('loading-state');
    searchEl       = document.getElementById('search');
    resetEl        = document.getElementById('reset-filters');
    emptyResetEl   = document.getElementById('empty-reset');
    visibleCountEl = document.getElementById('visible-count');
    totalCountEl   = document.getElementById('total-count');
    sortEl         = document.getElementById('sort');
    sliceNoteEl    = document.getElementById('slice-note');
    tabsEl         = document.getElementById('tabs');
    tagInputEl     = document.getElementById('tag-input');
    tagSuggestEl   = document.getElementById('tag-suggestions');
    tagSelectedEl  = document.getElementById('tag-selected');
    tagChipsEl     = document.getElementById('tag-chips');
    sidebarEl      = document.getElementById('sidebar');
    sidebarToggleEl = document.getElementById('sidebar-toggle');
    modalEl        = document.getElementById('detail-modal');
    institutionBtnEl = document.querySelector('.filter-group[data-filter="type"] button[data-value="institution"]');
    hoverEl        = buildHoverEl();

    initLang();
    applyI18n();
    bindLangSwitch();
    bindFilterButtons();
    bindSearch();
    bindSort();
    bindReset();
    bindTabs();
    bindTagFilter();
    bindSidebarToggle();
    bindModalClose();
    bindHeroHome();
    renderUpdatedRelative();

    parseHash();
    applyStateToControls();
    window.addEventListener('hashchange', onHashChange);

    fetch('data.json', { cache: 'no-cache' })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        records = Array.isArray(data) ? data : [];
        // Mastodon custom-emoji shortcody (např. trailing :bot:) se renderují jako
        // holý text — odstraníme je z jména hned, ať je čisté i pro hledání/řazení.
        records.forEach(function (r) { r.display_name = cleanName(r.display_name); });
        loadingEl.hidden = true;
        if (totalCountEl) totalCountEl.textContent = records.length;
        render();
        maybeOpenPendingAccount();
      })
      .catch(function (err) {
        loadingEl.hidden = true;
        cardsEl.innerHTML = '<p class="load-error">' + t('load_error') + '</p>';
        console.error('Catalog load failed:', err);
      });
  });

  // ========================================================
  // Bindings
  // ========================================================
  function bindFilterButtons() {
    document.querySelectorAll('.filter-group[data-filter="family"] button[data-value],' +
      '.filter-group[data-filter="type"] button[data-value],' +
      '.filter-group[data-filter="language"] button[data-value]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var section = btn.closest('.filter-group').getAttribute('data-filter');
        toggleSetValue(filters[section], btn.getAttribute('data-value'));
        btn.classList.toggle('active');
        render();
      });
    });
  }

  function bindSearch() {
    searchEl.addEventListener('input', function () {
      searchQuery = searchEl.value.trim().toLowerCase();
      render();
    });
  }

  function bindSort() {
    sortEl.addEventListener('change', function () {
      sortKey = sortEl.value;
      render();
    });
  }

  function bindReset() {
    resetEl.addEventListener('click', resetAll);
    emptyResetEl.addEventListener('click', resetAll);
  }

  function bindTabs() {
    tabsEl.querySelectorAll('.tab').forEach(function (tab) {
      tab.addEventListener('click', function () {
        slice = parseSlice(tab.getAttribute('data-slice'));
        render();
      });
    });
  }

  function bindSidebarToggle() {
    sidebarToggleEl.addEventListener('click', function () {
      var open = sidebarEl.classList.toggle('open');
      sidebarToggleEl.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
  }

  // Klik na hlavičkový obrázek = návrat na "Vše" (reset všech filtrů a řezů).
  function bindHeroHome() {
    var hero = document.getElementById('hero-home');
    if (hero) hero.addEventListener('click', resetAll);
  }

  // Odstraní Mastodon custom-emoji shortcody (`:bot:`, `:verified:` …) z jména.
  function cleanName(name) {
    return String(name == null ? '' : name)
      .replace(/:[a-zA-Z0-9_]+:/g, '')
      .replace(/\s{2,}/g, ' ')
      .trim();
  }

  // ========================================================
  // Tag filtr (autocomplete + dynamické chips)
  // ========================================================
  function bindTagFilter() {
    tagInputEl.addEventListener('input', function () { renderTagSuggestions(); });
    tagInputEl.addEventListener('focus', function () { renderTagSuggestions(); });
    tagInputEl.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        var first = tagSuggestEl.querySelector('li');
        if (first) addTag(first.getAttribute('data-tag'));
      } else if (e.key === 'Escape') {
        hideTagSuggestions();
      }
    });
    document.addEventListener('click', function (e) {
      if (!e.target.closest('.tag-autocomplete')) hideTagSuggestions();
    });
  }

  function addTag(tag) {
    if (!tag) return;
    filters.tag.add(tag);
    tagInputEl.value = '';
    hideTagSuggestions();
    render();
  }

  function removeTag(tag) {
    filters.tag.delete(tag);
    render();
  }

  function hideTagSuggestions() {
    tagSuggestEl.hidden = true;
    tagSuggestEl.innerHTML = '';
    tagInputEl.setAttribute('aria-expanded', 'false');
  }

  // Tagy dostupné v aktuálním výběru (slice + ostatní filtry kromě tagu), s četností.
  function availableTagCounts() {
    var counts = Object.create(null);
    sliceBase().filter(matchesExceptTag).forEach(function (rec) {
      (rec.categories || []).forEach(function (t) {
        counts[t] = (counts[t] || 0) + 1;
      });
    });
    return counts;
  }

  function renderTagSuggestions() {
    var q = tagInputEl.value.trim().toLowerCase();
    var counts = availableTagCounts();
    var list = Object.keys(counts)
      .filter(function (t) { return !filters.tag.has(t) && t.indexOf(q) !== -1; })
      .sort(function (a, b) { return counts[b] - counts[a] || a.localeCompare(b); })
      .slice(0, SUGGEST_MAX);

    tagSuggestEl.innerHTML = '';
    if (list.length === 0) { hideTagSuggestions(); return; }
    list.forEach(function (t) {
      var li = document.createElement('li');
      li.setAttribute('role', 'option');
      li.setAttribute('data-tag', t);
      li.innerHTML = '';
      var name = document.createElement('span');
      name.textContent = t;
      var c = document.createElement('span');
      c.className = 'tag-count';
      c.textContent = counts[t];
      li.appendChild(name);
      li.appendChild(c);
      li.addEventListener('click', function () { addTag(t); });
      tagSuggestEl.appendChild(li);
    });
    tagSuggestEl.hidden = false;
    tagInputEl.setAttribute('aria-expanded', 'true');
  }

  // Vybrané tagy (odstranitelné chips) + top-N návrhové chips.
  function renderTagUI() {
    tagSelectedEl.innerHTML = '';
    filters.tag.forEach(function (t) {
      var chip = document.createElement('button');
      chip.className = 'tag-chip tag-chip-selected';
      chip.innerHTML = '';
      chip.appendChild(document.createTextNode(t));
      var x = document.createElement('span');
      x.className = 'tag-x';
      x.setAttribute('aria-hidden', 'true');
      x.textContent = '×';
      chip.appendChild(x);
      chip.setAttribute('aria-label', 'Odebrat tag ' + t);
      chip.addEventListener('click', function () { removeTag(t); });
      tagSelectedEl.appendChild(chip);
    });

    var counts = availableTagCounts();
    var top = Object.keys(counts)
      .filter(function (t) { return !filters.tag.has(t); })
      .sort(function (a, b) { return counts[b] - counts[a] || a.localeCompare(b); })
      .slice(0, TAG_CHIP_COUNT);

    tagChipsEl.innerHTML = '';
    top.forEach(function (t) {
      var chip = document.createElement('button');
      chip.className = 'tag-chip';
      chip.appendChild(document.createTextNode(t));
      var c = document.createElement('span');
      c.className = 'tag-count';
      c.textContent = counts[t];
      chip.appendChild(c);
      chip.addEventListener('click', function () { addTag(t); });
      tagChipsEl.appendChild(chip);
    });
  }

  // ========================================================
  // Filtrování + řezy
  // ========================================================
  function toggleSetValue(set, value) {
    if (set.has(value)) set.delete(value); else set.add(value);
  }

  // Záznamy spadající do aktuálního řezu, bez sidebar filtrů (kromě Top N, které
  // řeší jen rodinu). Slouží jako základ pro počítání dostupných tagů.
  function sliceBase() {
    if (slice.kind === 'top') {
      return records.filter(function (r) {
        return filters.family.size === 0 || filters.family.has(r.family);
      });
    }
    return records.filter(inSlice);
  }

  function inSlice(rec) {
    if (slice.kind === 'platform') {
      return (rec.source_platforms || []).indexOf(slice.value) !== -1;
    }
    if (slice.kind === 'recent') {
      var d = daysSince(rec.created_at);
      return d !== null && d <= RECENT_DAYS;
    }
    return true; // all
  }

  function matchesExceptTag(rec) {
    if (filters.family.size && !filters.family.has(rec.family)) return false;
    if (filters.type.size && !filters.type.has(rec.type)) return false;
    if (filters.language.size && !filters.language.has(rec.language)) return false;
    if (searchQuery) {
      // Vyhledává jméno + handle + (skrytě) tagy — "f1" tak najde i účty,
      // které f1 nemají ve jméně, ale jsou tak otagované.
      var hay = (rec.display_name + ' ' + rec.id + ' ' +
                 (rec.categories || []).join(' ')).toLowerCase();
      if (hay.indexOf(searchQuery) === -1) return false;
    }
    return true;
  }

  function matchesTag(rec) {
    if (!filters.tag.size) return true;
    var cats = rec.categories || [];
    var ok = true;
    filters.tag.forEach(function (t) { if (cats.indexOf(t) === -1) ok = false; });
    return ok;
  }

  // Top N přepisuje ostatní filtry — kurátorský pohled, respektuje jen rodinu.
  function isTopSlice() { return slice.kind === 'top'; }

  function computeVisible() {
    if (isTopSlice()) {
      var field = TOP_FIELD[slice.metric] || 'followers';
      var isGain = slice.metric.indexOf('gain_') === 0;
      return records
        .filter(function (r) {
          if (filters.family.size && !filters.family.has(r.family)) return false;
          // Skokani: jen účty s kladným nárůstem a dostupnou předchozí hodnotou.
          if (isGain) return r[field] != null && r[field] > 0;
          return true;
        })
        .slice()
        .sort(function (a, b) { return (b[field] || 0) - (a[field] || 0); })
        .slice(0, slice.count);
    }
    var list = records.filter(function (r) {
      return inSlice(r) && matchesExceptTag(r) && matchesTag(r);
    });
    return sortList(list);
  }

  function sortList(list) {
    var copy = list.slice();
    switch (sortKey) {
      case 'followers':
        copy.sort(function (a, b) { return (b.followers || 0) - (a.followers || 0); });
        break;
      case 'posts':
        copy.sort(function (a, b) { return (b.posts_week || 0) - (a.posts_week || 0); });
        break;
      case 'added':
        copy.sort(function (a, b) {
          var da = a.created_at || '', db = b.created_at || '';
          if (da === db) return cmpName(a, b);
          if (!da) return 1; if (!db) return -1;       // bez data na konec
          return db < da ? -1 : 1;                      // novější (větší datum) první
        });
        break;
      default:
        copy.sort(cmpName);
    }
    return copy;
  }

  function cmpName(a, b) {
    return a.display_name.localeCompare(b.display_name, 'cs', { sensitivity: 'base' });
  }

  // ========================================================
  // Render
  // ========================================================
  function render() {
    syncTabsUI();
    updateSliceDimming();
    updateInstitutionFilterLabel();

    var visible = computeVisible();
    visibleCountEl.textContent = visible.length;

    renderTagUI();
    renderSliceNote();

    var anyFilter = filters.family.size || filters.type.size ||
      filters.language.size || filters.tag.size || searchQuery ||
      slice.kind !== 'all' || sortKey !== 'name';
    resetEl.hidden = !anyFilter;

    cardsEl.innerHTML = '';
    if (visible.length === 0) {
      emptyEl.hidden = false;
    } else {
      emptyEl.hidden = true;
      var frag = document.createDocumentFragment();
      visible.forEach(function (rec) { frag.appendChild(buildCard(rec)); });
      cardsEl.appendChild(frag);
    }

    writeHash();
  }

  function renderSliceNote() {
    var note = '';
    if (slice.kind === 'platform') {
      note = t('slice_platform') + platformLabel(slice.value);
    } else if (slice.kind === 'recent') {
      note = t('slice_recent_pre') + RECENT_DAYS + t('slice_recent_post');
    } else if (slice.kind === 'top') {
      note = t('slice_top_pre') + slice.count + ' ' + t('top_phrase_' + slice.metric) + t('slice_top_post');
    }
    sliceNoteEl.textContent = note;
    sliceNoteEl.hidden = note === '';
  }

  // Top N ztlumí (disabled) vše kromě rodiny.
  function updateSliceDimming() {
    var dim = isTopSlice();
    document.querySelectorAll('.filter-group[data-filter="type"],' +
      '.filter-group[data-filter="language"], .filter-group[data-filter="tag"],' +
      '.filter-sort, .filter-search').forEach(function (el) {
      el.classList.toggle('is-dimmed', dim);
      el.querySelectorAll('input, button, select').forEach(function (c) { c.disabled = dim; });
    });
  }

  function syncTabsUI() {
    var current = sliceToString(slice);
    tabsEl.querySelectorAll('.tab').forEach(function (tab) {
      tab.classList.toggle('is-active', tab.getAttribute('data-slice') === current);
    });
  }

  // ========================================================
  // Karta
  // ========================================================
  function buildCard(rec) {
    var card = document.createElement('article');
    card.className = 'card';
    card.tabIndex = 0;
    card.setAttribute('role', 'button');
    card.setAttribute('aria-label', t('card_detail') + rec.display_name);

    card.appendChild(buildAvatar(rec, 'card-avatar'));

    var body = document.createElement('div');
    body.className = 'card-body';

    var name = document.createElement('div');
    name.className = 'card-name';
    name.textContent = rec.display_name;

    var handle = document.createElement('a');
    handle.className = 'card-handle';
    handle.href = rec.profile_url;
    handle.target = '_blank';
    handle.rel = 'noopener';
    handle.textContent = '@' + rec.id;
    handle.addEventListener('click', function (e) { e.stopPropagation(); });

    body.appendChild(name);
    body.appendChild(handle);
    body.appendChild(buildLabels(rec));
    body.appendChild(buildStats(rec));

    card.appendChild(body);

    card.addEventListener('click', function () { openModal(rec); });
    card.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openModal(rec); }
    });
    if (HOVER_CAPABLE) attachHover(card, rec);

    return card;
  }

  function buildAvatar(rec, cls) {
    var avatar = document.createElement('div');
    avatar.className = cls;
    if (rec.avatar) {
      var img = document.createElement('img');
      img.src = rec.avatar;
      img.alt = '';
      img.loading = 'lazy';
      img.onerror = function () { avatar.classList.add('avatar-fallback'); img.remove(); };
      avatar.appendChild(img);
    } else {
      avatar.classList.add('avatar-fallback');
    }
    return avatar;
  }

  function buildLabels(rec) {
    var labels = document.createElement('div');
    labels.className = 'card-labels';
    var fam = document.createElement('span');
    fam.className = 'label label-family fam-' + rec.family;
    fam.textContent = familyLabel(rec.family);
    labels.appendChild(fam);
    var typ = document.createElement('span');
    typ.className = 'label label-type';
    typ.textContent = typeLabel(rec);
    labels.appendChild(typ);
    return labels;
  }

  function buildStats(rec) {
    var stats = document.createElement('div');
    stats.className = 'card-stats';
    stats.appendChild(stat(formatNumber(rec.followers), t('stat_followers')));
    stats.appendChild(stat(rec.posts_week, t('stat_posts_week')));
    return stats;
  }

  function stat(value, label) {
    var s = document.createElement('span');
    s.className = 'stat';
    var v = document.createElement('strong');
    v.textContent = value;
    s.appendChild(v);
    s.appendChild(document.createTextNode(' ' + label));
    return s;
  }

  // ========================================================
  // Hover preview
  // ========================================================
  function buildHoverEl() {
    var el = document.createElement('div');
    el.className = 'hover-preview';
    el.hidden = true;
    el.addEventListener('mouseenter', function () { clearTimeout(hoverHideTimer); });
    el.addEventListener('mouseleave', scheduleHoverHide);
    document.body.appendChild(el);
    return el;
  }

  function attachHover(card, rec) {
    card.addEventListener('mouseenter', function () {
      clearTimeout(hoverHideTimer);
      clearTimeout(hoverTimer);
      hoverTimer = setTimeout(function () { showHover(card, rec); }, HOVER_DELAY);
    });
    card.addEventListener('mouseleave', function () {
      clearTimeout(hoverTimer);
      scheduleHoverHide();
    });
  }

  function scheduleHoverHide() {
    clearTimeout(hoverHideTimer);
    hoverHideTimer = setTimeout(function () { hoverEl.hidden = true; }, HOVER_GRACE);
  }

  function showHover(card, rec) {
    hoverEl.innerHTML = '';

    var head = document.createElement('div');
    head.className = 'hover-head';
    head.appendChild(buildAvatar(rec, 'hover-avatar'));
    var ht = document.createElement('div');
    var hn = document.createElement('div');
    hn.className = 'hover-name';
    hn.textContent = rec.display_name;
    var hh = document.createElement('div');
    hh.className = 'hover-handle';
    hh.textContent = '@' + rec.id;
    ht.appendChild(hn);
    ht.appendChild(hh);
    head.appendChild(ht);
    hoverEl.appendChild(head);

    if (rec.bio) {
      var bio = document.createElement('div');
      bio.className = 'hover-bio';
      bio.appendChild(sanitizeBio(rec.bio));
      hoverEl.appendChild(bio);
    }

    var meta = document.createElement('div');
    meta.className = 'hover-meta';
    meta.appendChild(metaLine(platformsText(rec)));
    var added = relAdded(rec.created_at);
    if (added) meta.appendChild(metaLine(added));
    hoverEl.appendChild(meta);

    hoverEl.hidden = false;
    positionHover(card);
  }

  function positionHover(card) {
    var r = card.getBoundingClientRect();
    var pw = hoverEl.offsetWidth, ph = hoverEl.offsetHeight;
    var gap = 8;
    var left = r.left;
    var top = r.bottom + gap;
    if (top + ph > window.innerHeight && r.top - ph - gap > 0) top = r.top - ph - gap;
    if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
    if (left < 8) left = 8;
    hoverEl.style.left = (left + window.scrollX) + 'px';
    hoverEl.style.top = (top + window.scrollY) + 'px';
  }

  function metaLine(text) {
    var p = document.createElement('div');
    p.className = 'meta-line';
    p.textContent = text;
    return p;
  }

  function platformsText(rec) {
    var ps = (rec.source_platforms || []).map(platformLabel);
    return t('hover_source') + (ps.length ? ps.join(', ') : '—');
  }

  // ========================================================
  // Detail modal (<dialog>)
  // ========================================================
  function openModal(rec) {
    hoverEl.hidden = true;
    clearTimeout(hoverTimer);
    modalEl.innerHTML = '';
    modalEl.appendChild(buildModalContent(rec));
    if (typeof modalEl.showModal === 'function') {
      modalEl.showModal();
    } else {
      modalEl.setAttribute('open', '');  // fallback: position:fixed overlay přes CSS
      modalEl.classList.add('modal-fallback-open');
    }
  }

  function closeModal() {
    if (typeof modalEl.close === 'function' && modalEl.open) modalEl.close();
    modalEl.removeAttribute('open');
    modalEl.classList.remove('modal-fallback-open');
  }

  function bindModalClose() {
    // Klik mimo obsah (na backdrop dialogu)
    modalEl.addEventListener('click', function (e) {
      if (e.target === modalEl) closeModal();
    });
    // Escape u <dialog> ruší nativně přes 'cancel'
    modalEl.addEventListener('cancel', function () { closeModal(); });
    modalEl.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { e.preventDefault(); closeModal(); }
    });
  }

  function buildModalContent(rec) {
    var wrap = document.createElement('div');
    wrap.className = 'modal-inner';

    var close = document.createElement('button');
    close.className = 'modal-close';
    close.setAttribute('aria-label', t('modal_close'));
    close.innerHTML = '';
    close.textContent = '×';
    close.addEventListener('click', closeModal);
    wrap.appendChild(close);

    var head = document.createElement('div');
    head.className = 'modal-head';
    head.appendChild(buildAvatar(rec, 'modal-avatar'));
    var ht = document.createElement('div');
    ht.className = 'modal-headtext';
    var hn = document.createElement('div');
    hn.className = 'modal-name';
    hn.textContent = rec.display_name;
    var hh = document.createElement('a');
    hh.className = 'modal-handle';
    hh.href = rec.profile_url;
    hh.target = '_blank';
    hh.rel = 'noopener';
    hh.textContent = '@' + rec.id;
    ht.appendChild(hn);
    ht.appendChild(hh);
    head.appendChild(ht);
    wrap.appendChild(head);

    if (rec.bio) {
      var bio = document.createElement('div');
      bio.className = 'modal-bio';
      bio.appendChild(sanitizeBio(rec.bio));
      wrap.appendChild(bio);
    }

    wrap.appendChild(buildLabels(rec));

    if (rec.categories && rec.categories.length) {
      var cats = document.createElement('div');
      cats.className = 'modal-tags';
      rec.categories.forEach(function (cat) {
        var chip = document.createElement('button');
        chip.className = 'tag-chip';
        chip.textContent = cat;
        chip.addEventListener('click', function () {
          closeModal();
          if (isTopSlice()) slice = { kind: 'all' };
          filters.tag.add(cat);
          render();
        });
        cats.appendChild(chip);
      });
      wrap.appendChild(cats);
    }

    var stats = document.createElement('div');
    stats.className = 'modal-stats';
    stats.appendChild(modalStat(formatNumber(rec.followers), t('stat_followers')));
    stats.appendChild(modalStat(formatNumber(rec.posts_week), t('stat_posts_week')));
    stats.appendChild(modalStat(langLabel(rec.language), t('stat_language')));
    var added = relAdded(rec.created_at);
    if (added) stats.appendChild(modalStat('', added, true));
    wrap.appendChild(stats);

    var details = rec.source_details || [];
    if (details.length) {
      var sec = document.createElement('div');
      sec.className = 'modal-sources';
      var h = document.createElement('h3');
      h.textContent = t('modal_sources');
      sec.appendChild(h);
      details.forEach(function (d) {
        var label = platformLabel(d.platform) +
          (d.handle ? ' · ' + d.handle : '');
        if (d.url) {
          var a = document.createElement('a');
          a.className = 'source-link';
          a.href = d.url;
          a.target = '_blank';
          a.rel = 'noopener';
          a.textContent = label + ' ↗';
          sec.appendChild(a);
        } else {
          var span = document.createElement('span');
          span.className = 'source-link source-link-plain';
          span.textContent = label;
          sec.appendChild(span);
        }
      });
      wrap.appendChild(sec);
    }

    var actions = document.createElement('div');
    actions.className = 'modal-actions';
    var profile = document.createElement('a');
    profile.className = 'btn btn-primary';
    profile.href = rec.profile_url;
    profile.target = '_blank';
    profile.rel = 'noopener';
    profile.textContent = t('modal_open');
    actions.appendChild(profile);
    var follow = document.createElement('a');
    follow.className = 'btn btn-ghost';
    // Odkaz vede na profil účtu — Mastodon tam ukáže dialog „Sledovat", který
    // návštěvníka nechá zadat VLASTNÍ instanci (ne přihlášení na zpravobot.news).
    follow.href = rec.profile_url;
    follow.target = '_blank';
    follow.rel = 'noopener';
    follow.title = t('modal_follow_title');
    follow.textContent = t('modal_follow');
    actions.appendChild(follow);
    wrap.appendChild(actions);

    return wrap;
  }

  function modalStat(value, label, labelOnly) {
    var s = document.createElement('div');
    s.className = 'modal-stat';
    if (labelOnly) {
      s.classList.add('modal-stat-wide');
      s.textContent = label;
      return s;
    }
    var v = document.createElement('strong');
    v.textContent = value;
    var l = document.createElement('span');
    l.textContent = label;
    s.appendChild(v);
    s.appendChild(l);
    return s;
  }

  // ========================================================
  // Sanitizace bio (HTML z Mastodon note → whitelist a/br/p/span)
  // ========================================================
  function sanitizeBio(html) {
    var allowed = { A: 1, BR: 1, P: 1, SPAN: 1 };
    var doc = new DOMParser().parseFromString(String(html), 'text/html');
    var frag = document.createDocumentFragment();
    walkNodes(doc.body, frag, allowed);
    return frag;
  }

  function walkNodes(src, dest, allowed) {
    Array.prototype.forEach.call(src.childNodes, function (node) {
      if (node.nodeType === 3) {
        dest.appendChild(document.createTextNode(node.nodeValue));
        return;
      }
      if (node.nodeType !== 1) return;
      var tag = node.tagName;
      if (!allowed[tag]) { walkNodes(node, dest, allowed); return; }  // unwrap
      var el = document.createElement(tag.toLowerCase());
      if (tag === 'A') {
        var href = node.getAttribute('href') || '';
        if (/^https?:\/\//i.test(href)) {
          el.setAttribute('href', href);
          el.target = '_blank';
          el.rel = 'noopener noreferrer';
        }
      }
      walkNodes(node, el, allowed);
      dest.appendChild(el);
    });
  }

  // ========================================================
  // URL hash state
  // ========================================================
  function writeHash() {
    var parts = [];
    if (filters.family.size) parts.push('family=' + enc(setList(filters.family)));
    if (filters.type.size) parts.push('type=' + enc(setList(filters.type)));
    if (filters.language.size) parts.push('lang=' + enc(setList(filters.language)));
    if (filters.tag.size) parts.push('tag=' + enc(setList(filters.tag)));
    if (searchQuery) parts.push('q=' + enc(searchQuery));
    if (sortKey !== 'name') parts.push('sort=' + enc(sortKey));
    if (slice.kind !== 'all') parts.push('slice=' + enc(sliceToString(slice)));
    var hash = parts.join('&');
    suppressHash = true;
    if (hash) {
      if (location.hash.slice(1) !== hash) location.hash = hash;
    } else if (location.hash) {
      history.replaceState(null, '', location.pathname + location.search);
    }
    setTimeout(function () { suppressHash = false; }, 0);
  }

  function parseHash() {
    pendingAccountId = null;
    var hash = location.hash.replace(/^#/, '');
    if (!hash) return;
    filters.family.clear(); filters.type.clear();
    filters.language.clear(); filters.tag.clear();
    searchQuery = ''; sortKey = 'name'; slice = { kind: 'all' };

    hash.split('&').forEach(function (pair) {
      var i = pair.indexOf('=');
      if (i === -1) return;
      var key = pair.slice(0, i);
      var val = dec(pair.slice(i + 1));
      switch (key) {
        case 'family': splitList(val).forEach(function (v) { filters.family.add(v); }); break;
        case 'type': splitList(val).forEach(function (v) { filters.type.add(v); }); break;
        case 'lang': splitList(val).forEach(function (v) { filters.language.add(v); }); break;
        case 'tag': splitList(val).forEach(function (v) { filters.tag.add(v); }); break;
        case 'q': searchQuery = val.toLowerCase(); break;
        case 'sort': if (/^(name|followers|posts|added)$/.test(val)) sortKey = val; break;
        case 'slice': slice = parseSlice(val); break;
        case 'account': pendingAccountId = val; break;
      }
    });
  }

  // Otevře modal účtu odkazovaného přes #account=<id> (per-účet sdílecí stub).
  function maybeOpenPendingAccount() {
    if (!pendingAccountId) return;
    var id = pendingAccountId;
    pendingAccountId = null;
    for (var i = 0; i < records.length; i++) {
      if (records[i].id === id) { openModal(records[i]); return; }
    }
  }

  function onHashChange() {
    if (suppressHash) return;
    parseHash();
    applyStateToControls();
    render();
    maybeOpenPendingAccount();
  }

  // Promítne stav (z hashe) do ovládacích prvků v sidebaru.
  function applyStateToControls() {
    document.querySelectorAll('.filter-group button[data-value]').forEach(function (btn) {
      var section = btn.closest('.filter-group').getAttribute('data-filter');
      var set = filters[section];
      btn.classList.toggle('active', !!(set && set.has(btn.getAttribute('data-value'))));
    });
    searchEl.value = searchQuery;
    sortEl.value = sortKey;
  }

  // ========================================================
  // Slice (de)serializace
  // ========================================================
  function parseSlice(str) {
    if (!str || str === 'all') return { kind: 'all' };
    var p = str.split(':');
    if (p[0] === 'platform') return { kind: 'platform', value: p[1] };
    if (p[0] === 'recent') return { kind: 'recent' };
    if (p[0] === 'top') return { kind: 'top', metric: p[1], count: parseInt(p[2], 10) || 10 };
    return { kind: 'all' };
  }

  function sliceToString(s) {
    if (s.kind === 'platform') return 'platform:' + s.value;
    if (s.kind === 'recent') return 'recent';
    if (s.kind === 'top') return 'top:' + s.metric + ':' + s.count;
    return 'all';
  }

  // ========================================================
  // Reset
  // ========================================================
  function resetAll() {
    filters.family.clear(); filters.type.clear();
    filters.language.clear(); filters.tag.clear();
    searchQuery = ''; searchEl.value = '';
    sortKey = 'name'; sortEl.value = 'name';
    slice = { kind: 'all' };
    tagInputEl.value = '';
    document.querySelectorAll('.filter-group button.active')
      .forEach(function (b) { b.classList.remove('active'); });
    render();
  }

  // ========================================================
  // Datum / čas
  // ========================================================
  function daysSince(iso) {
    if (!iso) return null;
    var then = new Date(iso + 'T00:00:00');
    if (isNaN(then.getTime())) return null;
    return Math.floor((Date.now() - then.getTime()) / 86400000);
  }

  function plural(n, one, few, many) {
    if (n === 1) return one;
    if (n >= 2 && n <= 4) return few;
    return many;
  }

  // "přidán před X" / "added X ago" — větvíme podle jazyka (čeština má složitější
  // skloňování než angličtina).
  function relAdded(iso) {
    var d = daysSince(iso);
    if (d === null) return '';
    if (lang === 'en') {
      if (d <= 0) return 'added today';
      if (d === 1) return 'added yesterday';
      if (d < 31) return 'added ' + d + ' days ago';
      var em = Math.round(d / 30);
      if (em < 12) return 'added ' + em + (em === 1 ? ' month ago' : ' months ago');
      var ey = Math.round(d / 365);
      return 'added ' + ey + (ey === 1 ? ' year ago' : ' years ago');
    }
    if (d <= 0) return 'přidán dnes';
    if (d === 1) return 'přidán včera';
    if (d < 31) return 'přidán před ' + d + ' ' + plural(d, 'dnem', 'dny', 'dny');
    var m = Math.round(d / 30);
    if (m < 12) return 'přidán před ' + m + ' ' + plural(m, 'měsícem', 'měsíci', 'měsíci');
    var y = Math.round(d / 365);
    return 'přidán před ' + y + ' ' + plural(y, 'rokem', 'lety', 'lety');
  }

  function renderUpdatedRelative() {
    var el = document.getElementById('updated-relative');
    if (!el) return;
    var iso = document.body.getAttribute('data-updated');
    var d = daysSince(iso);
    if (d === null) return;
    var txt;
    if (lang === 'en') {
      txt = d <= 0 ? '(today)' : d === 1 ? '(yesterday)' : '(' + d + ' days ago)';
    } else if (d <= 0) {
      txt = '(dnes)';
    } else if (d === 1) {
      txt = '(včera)';
    } else {
      txt = '(před ' + d + ' ' + plural(d, 'dnem', 'dny', 'dny') + ')';
    }
    el.textContent = ' ' + txt;
  }

  // ========================================================
  // Utils
  // ========================================================
  function formatNumber(n) {
    return String(n == null ? 0 : n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  }
  function setList(set) { return Array.from(set).join(','); }
  function splitList(s) { return s.split(',').filter(Boolean); }
  function enc(s) { return encodeURIComponent(s); }
  function dec(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
})();
