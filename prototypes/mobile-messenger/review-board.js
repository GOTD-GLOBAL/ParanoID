import { SCREEN_GROUPS } from "./prototype.js";

const params = new URLSearchParams(window.location.search);
const requestedGroup = Number.parseInt(params.get("group") || "0", 10);
const groupIndex = Number.isInteger(requestedGroup)
  ? Math.min(Math.max(requestedGroup, 0), SCREEN_GROUPS.length - 1)
  : 0;
const platform = params.get("platform") === "android" ? "android" : "ios";
const theme = params.get("theme") === "dark" ? "dark" : "light";
const group = SCREEN_GROUPS[groupIndex];

document.querySelector("#review-title").textContent = `${group.title} · ${platform === "ios" ? "iOS" : "Android"}`;
document.querySelector("#review-meta").innerHTML = `${group.screens.length} экранов<br>${theme === "dark" ? "Тёмная" : "Светлая"} тема · группа ${groupIndex + 1}/${SCREEN_GROUPS.length}`;
document.title = `${group.title} · visual review`;

document.querySelector("#review-grid").innerHTML = group.screens.map((screen) => {
  const query = new URLSearchParams({ screen: screen.id, platform, theme, chrome: "0" });
  return `<figure class="review-card">
    <div class="review-viewport"><iframe title="${screen.title}" loading="eager" src="./?${query}"></iframe></div>
    <figcaption><strong>${screen.title}</strong><code>${screen.id}</code></figcaption>
  </figure>`;
}).join("");
