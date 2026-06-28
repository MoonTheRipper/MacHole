(function () {
  "use strict";

  var API_URL = "https://api.github.com/repos/MoonTheRipper/MacHole/releases/latest";
  var RELEASES_URL = "https://github.com/MoonTheRipper/MacHole/releases";
  var PREFERRED_ASSETS = ["MacHole.dmg", "MacHole.zip"];

  var downloadBtn = document.getElementById("downloadBtn");
  var versionText = document.getElementById("versionText");
  var notesSection = document.getElementById("notesSection");
  var releaseNotes = document.getElementById("releaseNotes");

  function showComingSoon() {
    if (versionText) versionText.textContent = "Coming soon";
    if (downloadBtn) downloadBtn.setAttribute("href", RELEASES_URL);
  }

  function formatDate(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    try {
      return d.toLocaleDateString(undefined, {
        year: "numeric",
        month: "long",
        day: "numeric"
      });
    } catch (e) {
      return d.toISOString().slice(0, 10);
    }
  }

  function findDownloadUrl(release) {
    var assets = release.assets || [];
    for (var p = 0; p < PREFERRED_ASSETS.length; p++) {
      for (var i = 0; i < assets.length; i++) {
        if (assets[i] && assets[i].name === PREFERRED_ASSETS[p] && assets[i].browser_download_url) {
          return assets[i].browser_download_url;
        }
      }
    }
    return release.html_url || RELEASES_URL;
  }

  function applyRelease(release) {
    if (!release || (!release.tag_name && !release.name)) {
      showComingSoon();
      return;
    }

    var version = release.tag_name || release.name;
    var date = formatDate(release.published_at || release.created_at);

    if (versionText) {
      versionText.textContent = date ? version + " · " + date : version;
    }

    if (downloadBtn) {
      downloadBtn.setAttribute("href", findDownloadUrl(release));
    }

    var body = (release.body || "").trim();
    if (body && notesSection && releaseNotes) {
      releaseNotes.textContent = body;
      notesSection.hidden = false;
    }
  }

  function load() {
    if (typeof fetch !== "function") {
      showComingSoon();
      return;
    }

    fetch(API_URL, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (resp) {
        if (!resp.ok) {
          throw new Error("Request failed: " + resp.status);
        }
        return resp.json();
      })
      .then(function (data) {
        applyRelease(data);
      })
      .catch(function () {
        showComingSoon();
      });
  }

  load();
})();
