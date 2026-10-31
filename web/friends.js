(() => {
  const button = document.querySelector("#open-grove");
  if (!button) return;

  const rawUsername = new URLSearchParams(window.location.search)
    .get("username")
    ?.trim()
    .replace(/^@+/, "")
    .toLowerCase();

  if (!rawUsername || !/^[a-z0-9_]{3,24}$/.test(rawUsername)) return;

  const appURL = new URL("nz.co.thinkingai.grove://friends");
  appURL.searchParams.set("username", rawUsername);
  button.href = appURL.toString();
})();
