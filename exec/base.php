<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3/dist/css/bootstrap.min.css" rel="stylesheet" crossorigin="anonymous">
<!-- tablesort core does string sort only — load the number + date plugins so
     numeric columns sort numerically and ISO dates sort chronologically by type,
     not just because the data happens to be lex-friendly. -->
<script src="https://cdn.jsdelivr.net/npm/tablesort@latest/dist/tablesort.min.js" crossorigin="anonymous"></script>
<script src="https://cdn.jsdelivr.net/npm/tablesort@latest/dist/sorts/tablesort.number.min.js" crossorigin="anonymous"></script>
<script src="https://cdn.jsdelivr.net/npm/tablesort@latest/dist/sorts/tablesort.date.min.js" crossorigin="anonymous"></script>
<style>
#iframe-container {
    width: 100%;
}
table.sortable thead th[role="columnheader"]:not(.no-sort) {
    cursor: pointer;
    user-select: none;
    position: relative;
    padding-right: 18px;
}
table.sortable thead th[role="columnheader"]:not(.no-sort)::after {
    content: " \2195";
    opacity: 0.35;
    font-size: 0.85em;
    position: absolute;
    right: 6px;
}
table.sortable thead th[aria-sort="ascending"]::after  { content: " \2191"; opacity: 1; }
table.sortable thead th[aria-sort="descending"]::after { content: " \2193"; opacity: 1; }
</style>
<script>
function resolveTheme() {
    var theme = 'light';
    try {
        if (window.top && window.top !== window && window.top.document && window.top.document.body) {
            var parentMode = window.top.document.body.getAttribute('data-mode');
            if (parentMode) { theme = parentMode; }
        }
    } catch (e) {}
    return theme;
}

function updateLinkTheme(theme) {
    document.querySelectorAll('a.link-dark, a.link-light').forEach(function (link) {
        link.classList.remove('link-dark', 'link-light');
        link.classList.add(theme === 'dark' ? 'link-light' : 'link-dark');
    });
}

document.addEventListener('DOMContentLoaded', function () {
    var theme = resolveTheme();
    document.documentElement.setAttribute('data-bs-theme', theme);
    updateLinkTheme(theme);

    try {
        if (window.top && window.top !== window && window.top.document && window.top.document.body) {
            new MutationObserver(function () {
                var t = resolveTheme();
                document.documentElement.setAttribute('data-bs-theme', t);
                updateLinkTheme(t);
            }).observe(window.top.document.body, { attributes: true, attributeFilter: ['data-mode', 'class'] });
        }
    } catch (e) {}

    // Initialise tablesort on every <table class="sortable">.
    // Per-row sort values can be set via data-sort="..." on <td>; default
    // sorted column can be marked with class="sort-default" on the <th>.
    if (typeof Tablesort === 'function') {
        document.querySelectorAll('table.sortable').forEach(function (t) { new Tablesort(t); });
    }
});
</script>
