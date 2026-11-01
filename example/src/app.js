const res = await fetch("/data/settings.json");
const settings = await res.json();
document.getElementById("message").textContent = settings.message;
