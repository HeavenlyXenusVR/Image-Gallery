import { useState } from "react";
import { Download, ExternalLink, Loader2 } from "lucide-react";
import { apiFetchBlob, apiUrl, downloadBlob } from "../api.js";
import { glassPointerMove, Page } from "../components/ui.jsx";
import swarmpanelLogo from "../assets/projects/swarmpanel.png";
import lumisoundLogo from "../assets/projects/lumisound.png";
import nyxframeLogo from "../assets/projects/nyxframe.png";

const PROJECTS = [
  {
    id: "swarmpanel",
    name: "SwarmPanel",
    tagline: "Dashboard & control panel for a Discord bot swarm.",
    logo: swarmpanelLogo,
    kind: "link",
    href: "https://swarmpanel.xenusanimations.studio",
  },
  {
    id: "lumisound",
    name: "Lumisound",
    tagline: "iOS music app. Downloads the latest build straight from GitHub.",
    logo: lumisoundLogo,
    kind: "download",
    // Both hit /api/projects/<id>/download on this same backend -- see
    // routes.lua's download_latest_ipa doc comment for why (repo privacy).
    downloadPath: "/api/projects/lumisound/download",
  },
  {
    id: "nyxframe",
    name: "Nyxframe",
    tagline: "This site's own native iOS app. Downloads the latest build straight from GitHub.",
    logo: nyxframeLogo,
    kind: "download",
    downloadPath: "/api/projects/nyxframe/download",
  },
];

function ProjectCard({ project, ctx }) {
  const [busy, setBusy] = useState(false);

  async function handleDownload() {
    if (busy) return;
    setBusy(true);
    try {
      const { blob, filename } = await apiFetchBlob(apiUrl(project.downloadPath));
      downloadBlob(blob, filename);
      ctx.showToast(`${project.name} download started.`, "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  const inner = (
    <>
      <div className="project-card-logo">
        <img src={project.logo} alt="" loading="lazy" decoding="async" />
      </div>
      <div className="project-card-copy">
        <h3>{project.name}</h3>
        <p>{project.tagline}</p>
      </div>
      <div className="project-card-cta">
        {project.kind === "link" ? (
          <span><ExternalLink size={16} />Open</span>
        ) : (
          <span>{busy ? <Loader2 size={16} className="vp-transcoding-spin" /> : <Download size={16} />}{busy ? "Fetching…" : "Download latest"}</span>
        )}
      </div>
    </>
  );

  if (project.kind === "link") {
    return (
      <a
        className="project-card liquid-glass"
        href={project.href}
        target="_blank"
        rel="noopener noreferrer"
        onPointerMove={glassPointerMove}
      >
        {inner}
      </a>
    );
  }

  return (
    <button
      type="button"
      className="project-card liquid-glass"
      onClick={handleDownload}
      disabled={busy}
      onPointerMove={glassPointerMove}
    >
      {inner}
    </button>
  );
}

export function OtherProjectsPage({ ctx }) {
  return (
    <Page eyebrow="Elsewhere" title="My Other Projects" lede="A couple of other things I've built.">
      <div className="project-card-grid">
        {PROJECTS.map((project) => <ProjectCard project={project} ctx={ctx} key={project.id} />)}
      </div>
    </Page>
  );
}
