import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { CalendarDays, Link as LinkIcon, MapPin, Settings } from "lucide-react";
import { cachedApiFetch } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { ProfileActions } from "../components/social.jsx";
import { Avatar, ChipRow, CollectionMini, Notice, NotFound, Page, SkeletonGrid, UserMini } from "../components/ui.jsx";
import { formatDate, numberish, safeColor } from "../utils/format.js";
import { profileClassName } from "../utils/appearance.js";
import { preloadMediaAssets } from "../utils/media.js";

export function ProfilePage({ ctx }) {
  const { username } = useParams();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadProfile = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const payload = await cachedApiFetch(`/api/users/${encodeURIComponent(username)}/profile`, { ttl: 20_000, staleTtl: 5 * 60_000 });
      setData(payload);
      preloadMediaAssets(payload.media || [], { limit: 6 });
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  }, [username]);

  useEffect(() => {
    loadProfile();
  }, [loadProfile]);

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
  const stats = [
    ["posts", profile.media_count || data.media?.length || 0],
    ["downloads", profile.download_count || 0],
    ...(profile.show_liked_count === false ? [] : [["likes", profile.like_count || 0]]),
    ...(showFollowCounts ? [["followers", profile.follower_count || 0], ["following", profile.following_count || 0]] : []),
    ...(showFriends ? [["friends", profile.friend_count || data.friends?.length || 0]] : []),
  ];
  const profileClasses = profileClassName(profileSettings);

  return (
    <Page title={profile.display_name || profile.username} eyebrow={`@${profile.username}`} actions={isOwner ? <Link className="button-link" to="/settings"><Settings size={16} />Settings</Link> : null}>
      <section className={`profile-hero ${profileClasses}`} style={{ "--accent": safeColor(profile.profile_color || ctx.settings.accent_color) }}>
        <Avatar user={profile} large />
        <div>
          <h2>{profile.profile_headline || profile.display_name || profile.username}</h2>
          {profile.bio ? <p>{profile.bio}</p> : null}
          <div className="profile-meta">
            {profile.location_label ? <span><MapPin size={14} />{profile.location_label}</span> : null}
            {profile.website_url ? <a href={profile.website_url} target="_blank" rel="noreferrer"><LinkIcon size={14} />{profile.website_url.replace(/^https?:\/\//, "")}</a> : null}
            {profileSettings.profile_show_joined_date !== false && profile.created_at ? <span><CalendarDays size={14} />{formatDate(profile.created_at)}</span> : null}
          </div>
          <ChipRow values={profile.featured_tags || []} />
          <div className="profile-stats">
            {stats.map(([label, value]) => <span key={label}><strong>{numberish(value)}</strong>{label}</span>)}
          </div>
        </div>
        {!isOwner ? <ProfileActions ctx={ctx} user={profile} onChanged={loadProfile} /> : null}
      </section>
      <section className={`profile-sections ${profileClasses}`}>
        {showUploads ? <div className="profile-posts">
          <div className="section-head"><h2>Posts</h2><span>{data.media?.length || 0}</span></div>
          <MediaGrid ctx={ctx} items={data.media || []} emptyTitle="No public posts" />
        </div> : null}
        <aside className="profile-rail">
          {showCollections ? <div className="side-box"><h3>Collections</h3>{(data.collections || []).map((collection) => <CollectionMini collection={collection} key={collection.id} />)}{!data.collections?.length ? <p>No public collections.</p> : null}</div> : null}
          {showFriends ? <div className="side-box"><h3>Friends</h3>{(data.friends || []).map((friend) => <UserMini user={friend} key={friend.id} />)}{!data.friends?.length ? <p>No friends shown.</p> : null}</div> : null}
        </aside>
      </section>
    </Page>
  );
}
