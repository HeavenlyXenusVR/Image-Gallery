export function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / (1024 ** index)).toFixed(index ? 1 : 0)} ${units[index]}`;
}

export function numberish(value) {
  return new Intl.NumberFormat().format(Number(value || 0));
}

export function initials(value) {
  return String(value || "IG").trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "IG";
}

export function safeColor(value) {
  return /^#[0-9a-f]{6}$/i.test(value || "") ? value : "#37c9a7";
}

export function friendLabel(status) {
  if (status === "friends") return "Friends";
  if (status === "pending_out") return "Pending";
  if (status === "pending_in") return "Respond";
  if (status === "self") return "You";
  return "Friend";
}
