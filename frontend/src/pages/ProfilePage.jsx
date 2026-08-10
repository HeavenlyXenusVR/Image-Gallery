import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { BadgeCheck, CalendarDays, Images, Link as LinkIcon, MapPin, Settings, Users } from "lucide-react";
import { cachedApiFetch } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { ProfileActions } from "../components/social.jsx";
import { Avatar, ChipRow, CollectionMini, Notice, NotFound, Page, PresencePill, ResilientImage, SkeletonGrid, UserMini } from "../components/ui.jsx";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { formatDate, numberish, safeExternalUrl } from "../utils/format.js";
import { profileClassName, profileStyle } from "../utils/appearance.js";
import { mediaImageSources, preloadMediaAssets } from "../utils/media.js";

export function ProfilePage({ ctx }) {
  const { username } = useParams();
  const [data, setData] = useState(null);
  const [social, setSocial] = useState({ followers: [], following: [], friends: [] });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadProfile = useCallback(async ({ background = false } = {}) => {
    if (!background) {
      setLoading(true);
      setError("");
    }
    try {
      const payload = await cachedApiFetch(`/api/users/${encodeURIComponent(username)}/profile`, {
        ttl: background ? 8_000 : 20_000,
        staleTtl: 30_000,
        allowStale: false,
      });
      setData(payload);
      preloadMediaAssets(payload.media || [], { limit: 6 });
      if (payload.user?.id) {
        const [followers, following, friends] = await Promise.allSettled([
          cachedApiFetch(`/api/users/${payload.user.id}/followers`, { ttl: background ? 8_000 : 20_000, staleTtl: 30_000, allowStale: false }),
          cachedApiFetch(`/api/users/${payload.user.id}/following`, { ttl: background ? 8_000 : 20_000, staleTtl: 30_000, allowStale: false }),
          cachedApiFetch(`/api/users/${payload.user.id}/friends`, { ttl: background ? 8_000 : 20_000, staleTtl: 30_000, allowStale: false }),
        ]);
        setSocial({
          followers: followers.status === "fulfilled" ? followers.value.users || [] : [],
          following: following.status === "fulfilled" ? following.value.users || [] : [],
          friends: friends.status === "fulfilled" ? friends.value.friends || [] : [],
        });
      }
    } catch (fetchError) {
      if (!background) setError(fetchError.message);
    } finally {
      if (!background) setLoading(false);
    }
  }, [username]);

  useEffect(() => {
    loadProfile();
  }, [loadProfile]);

  useLiveRefresh(() => loadProfile({ background: true }), { enabled: Boolean(username), interval: 20_000 });

  if (loading) return <Page title="Profile" eyebrow="Loading"><SkeletonGrid count={4} /></Page>;
  if (error) return <Page title="Profile" eyebrow="Error"><Notice kind="error">{error}</Notice></Page>;
  if (!data?.user) return <NotFound />;

  const profile = data.user;
  const isOwner = ctx.user && ctx.user.username === profile.username;
  const profileSettings = { ...ctx.settings, ...(profile.user_settings || {}) };
  const showFollowCounts = profileSettings.profile_show_follow_counts !== false;
  const showUploads = profileSettings.profile_show_uploads !== false;
  const showCollections = profileSettings.profile_show_collections !== false;
  const showFriends = profileSettings.profile_show_friends !== false;
  const featuredPanel = profileSettings.profile_featured_panel || "uploads";
  const stats = [
    ["posts", profile.media_count || data.media?.length || 0],
    ["downloads", profile.download_count || 0],
    ...(profile.show_liked_count === false ? [] : [["likes", profile.like_count || 0]]),
    ...(showFollowCounts ? [["followers", profile.follower_count || 0], ["following", profile.following_count || 0]] : []),
    ...(showFriends ? [["friends", profile.friend_count || data.friends?.length || 0]] : []),
  ];
  const profileClasses = profileClassName(profileSettings);
  const profileSurface = profileStyle({ ...profileSettings, accent_color: profile.profile_color || ctx.settings.accent_color }, ctx.settings.accent_color);
  const featuredItems = featuredPanel === "collections" ? (data.collections || []) : featuredPanel === "friends" ? (data.friends || []) : (data.media || []);

  return (
    <Page
      title={profile.display_name || profile.username}
      eyebrow={`@${profile.username}`}
      lede={isOwner ? "Your public gallery identity, featured work, and social surfaces." : "Public gallery identity, featured work, and social surfaces."}
      className="page-profile"
      actions={isOwner ? <Link className="button-link" to="/settings"><Settings size={16} />Settings</Link> : null}
    >
      <section className={`profile-hero ${profileClasses}`} style={profileSurface}>
        <div className="profile-hero-main">
          <span className="profile-kicker">@{profile.username}</span>
          <h2>{profile.profile_headline || profile.display_name || profile.username}</h2>
          <div className="profile-hero-status">
            <PresencePill user={profile} />
            {isOwner ? <span className="profile-owner-pill">Owner View</span> : null}
            {profile.discord_verified_at ? (
              <span className="profile-discord-verified" title={profile.discord_username ? `Verified via Discord as @${profile.discord_username}` : "Verified via Discord"}>
                <BadgeCheck size={14} />Discord Verified
              </span>
            ) : null}
          </div>
          {profile.bio ? <p>{profile.bio}</p> : null}
          <div className="profile-meta">
            {profile.location_label ? <span><MapPin size={14} />{profile.location_label}</span> : null}
            {safeExternalUrl(profile.website_url) ? <a href={safeExternalUrl(profile.website_url)} target="_blank" rel="noreferrer"><LinkIcon size={14} />{safeExternalUrl(profile.website_url).replace(/^https?:\/\//, "")}</a> : null}
            {profileSettings.profile_show_joined_date !== false && profile.created_at ? <span><CalendarDays size={14} />{formatDate(profile.created_at)}</span> : null}
          </div>
          <ChipRow values={profile.featured_tags || []} />
          {!isOwner ? <ProfileActions ctx={ctx} user={profile} onChanged={loadProfile} /> : null}
        </div>
        <div className="profile-hero-side">
          <div className="profile-avatar-card">
            <Avatar user={profile} large />
            <div>
              <strong>{profile.display_name || profile.username}</strong>
              <small>{profile.profile_headline || "Gallery identity"}</small>
            </div>
          </div>
          <div className="profile-stat-grid">
            {stats.map(([label, value]) => (
              <article className="profile-stat-card" key={label}>
                <strong>{numberish(value)}</strong>
                <span>{label}</span>
              </article>
            ))}
          </div>
        </div>
      </section>
      <section className={`profile-showcase ${profileClasses}`} style={profileSurface}>
        <article className="profile-feature-card">
          <div className="section-head"><h2>{featuredPanel === "collections" ? "Featured Collections" : featuredPanel === "friends" ? "Featured Friends" : "Featured Posts"}</h2><Images size={18} /></div>
          <div className="profile-feature-strip">
            {featuredPanel === "collections" ? featuredItems.slice(0, 4).map((collection) => <CollectionMini collection={collection} key={collection.id} />) : null}
            {featuredPanel === "friends" ? featuredItems.slice(0, 6).map((friend) => <UserMini user={friend} key={friend.id} />) : null}
            {featuredPanel === "uploads" ? featuredItems.slice(0, 4).map((item) => <Link className="profile-media-mini" to={`/media/${item.id}`} key={item.id}><ResilientImage sources={mediaImageSources(item, { width: 420, previewSize: "detail" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "profile-featured" }} alt="" loading="lazy" decoding="async" /><span>{item.title || "Untitled"}</span></Link>) : null}
            {!featuredItems.length ? <p>No featured items yet.</p> : null}
          </div>
        </article>
        <article className="profile-feature-card">
          <div className="section-head"><h2>Social</h2><Users size={18} /></div>
          <div className="profile-social-preview">
            <div><strong>{numberish(profile.follower_count || social.followers.length)}</strong><span>Followers</span></div>
            <div><strong>{numberish(profile.following_count || social.following.length)}</strong><span>Following</span></div>
            <div><strong>{numberish(profile.friend_count || social.friends.length)}</strong><span>Friends</span></div>
          </div>
          <div className="profile-social-people">
            {social.followers.slice(0, 3).map((user) => <UserMini user={user} key={`follower-${user.id}`} />)}
            {!social.followers.length ? <p>No followers shown yet.</p> : null}
          </div>
        </article>
      </section>
      <section className={`profile-sections ${profileClasses}`} style={profileSurface}>
        {showUploads ? <div className="profile-posts">
          <div className="section-head"><h2>Posts</h2><span>{data.media?.length || 0}</span></div>
          <MediaGrid ctx={ctx} items={data.media || []} emptyTitle="No public posts" onOpen={ctx.openLightbox} />
        </div> : null}
        <aside className="profile-rail">
          {showCollections ? <div className="side-box"><h3>Collections</h3>{(data.collections || []).map((collection) => <CollectionMini collection={collection} key={collection.id} />)}{!data.collections?.length ? <p>No public collections.</p> : null}</div> : null}
          {showFriends ? <div className="side-box"><h3>Friends</h3>{(data.friends || []).map((friend) => <UserMini user={friend} key={friend.id} />)}{!data.friends?.length ? <p>No friends shown.</p> : null}</div> : null}
        </aside>
      </section>
    </Page>
  );
}
