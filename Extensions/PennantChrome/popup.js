// The popup: whether Pennant on this Mac is reachable, and a way to see its window.
function refresh() {
  chrome.runtime.sendMessage('status', (s) => {
    const on = s && s.connected;
    document.getElementById('dot').classList.toggle('on', !!on);
    document.getElementById('line').textContent = on
      ? `Connected to Pennant on this Mac${s.tabs ? ` · ${s.tabs} tab${s.tabs === 1 ? '' : 's'}` : ''}`
      : "Pennant isn't running on this Mac";
  });
}
chrome.runtime.sendMessage('connect', () => setTimeout(refresh, 600));
refresh();
document.getElementById('show').addEventListener('click', () => chrome.runtime.sendMessage('show', () => window.close()));
