import { useState } from "react";
import { LogIn, ShieldCheck } from "lucide-react";
import { apiFetch } from "../api.js";
import { Page, Segmented } from "../components/ui.jsx";

export function AuthPage({ ctx }) {
  const [mode, setMode] = useState("login");
  const [form, setForm] = useState({ username: "", password: "", email: "", display_name: "" });
  const [busy, setBusy] = useState(false);
  const [pendingToken, setPendingToken] = useState("");
  const [code, setCode] = useState("");

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
      if (data.needs_2fa) {
        setPendingToken(data.pending_token);
      } else {
        ctx.loginWith(data);
      }
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function submitCode(event) {
    event.preventDefault();
    setBusy(true);
    try {
      const data = await apiFetch("/api/auth/2fa/verify", {
        method: "POST",
        body: JSON.stringify({ pending_token: pendingToken, code }),
        token: "",
      });
      ctx.loginWith(data);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  if (pendingToken) {
    return (
      <Page title="Two-factor authentication" eyebrow="Account">
        <form className="auth-card stacked-form" onSubmit={submitCode}>
          <p><ShieldCheck size={16} /> Enter the 6-digit code from your authenticator app, or one of your recovery codes.</p>
          <label className="field">
            <span>Code</span>
            <input value={code} onChange={(event) => setCode(event.target.value)} inputMode="numeric" autoFocus required />
          </label>
          <button className="primary" disabled={busy} type="submit">{busy ? "Verifying" : "Verify"}</button>
          <button type="button" onClick={() => { setPendingToken(""); setCode(""); }}>Back to login</button>
        </form>
      </Page>
    );
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
