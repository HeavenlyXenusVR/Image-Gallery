import { useState } from "react";
import { LogIn } from "lucide-react";
import { apiFetch } from "../api.js";
import { Page, Segmented } from "../components/ui.jsx";

export function AuthPage({ ctx }) {
  const [mode, setMode] = useState("login");
  const [form, setForm] = useState({ username: "", password: "", email: "", display_name: "" });
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    try {
      const payload = mode === "login"
        ? { username: form.username, password: form.password }
        : form;
      const data = await apiFetch(mode === "login" ? "/api/auth/login" : "/api/auth/register", {
        method: "POST",
        body: JSON.stringify(payload),
        token: "",
      });
      ctx.loginWith(data);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Page title={mode === "login" ? "Login" : "Register"} eyebrow="Account">
      <form className="auth-card stacked-form" onSubmit={submit}>
        <Segmented value={mode} onChange={setMode} options={[["login", "Login"], ["register", "Register"]]} />
        <label className="field"><span>Username</span><input value={form.username} onChange={(event) => setForm((current) => ({ ...current, username: event.target.value }))} required /></label>
        {mode === "register" ? <label className="field"><span>Display name</span><input value={form.display_name} onChange={(event) => setForm((current) => ({ ...current, display_name: event.target.value }))} /></label> : null}
        {mode === "register" ? <label className="field"><span>Email</span><input type="email" value={form.email} onChange={(event) => setForm((current) => ({ ...current, email: event.target.value }))} /></label> : null}
        <label className="field"><span>Password</span><input type="password" value={form.password} onChange={(event) => setForm((current) => ({ ...current, password: event.target.value }))} required /></label>
        <button className="primary" disabled={busy} type="submit"><LogIn size={16} />{busy ? "Working" : mode === "login" ? "Login" : "Create Account"}</button>
      </form>
    </Page>
  );
}
