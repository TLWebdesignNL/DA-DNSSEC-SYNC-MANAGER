<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3/dist/css/bootstrap.min.css" rel="stylesheet" crossorigin="anonymous">
<style>
#iframe-container {
    width: 100%;
}
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
});
</script>
