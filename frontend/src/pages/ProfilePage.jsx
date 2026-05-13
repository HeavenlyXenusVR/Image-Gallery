import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { Settings } from "lucide-react";
import { cachedApiFetch } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { ProfileActions } from "../components/social.jsx";
import { Avatar, CollectionMini, Notice, NotFound, Page, SkeletonGrid, UserMini } from "../components/ui.jsx";
import { safeColor } from "../utils/format.js";
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

  return (
    <Page title={profile.display_name || profile.username} eyebrow={`@${profile.username}`} actions={isOwner ? <Link className="button-link" to="/settings"><Settings size={16} />Settings</Link> : null}>
      <section className="profile-hero" style={{ "--accent": safeColor(profile.profile_color || ctx.settings.accent_color) }}>
        <Avatar user={profile} large />
        <div>
          <h2>{profile.profile_headline || profile.display_name || profile.username}</h2>
          {profile.bio ? <p>{profile.bio}</p> : null}
          <div className="profile-stats">
            <span>{profile.media_count || data.media?.length || 0} posts</span>
            <span>{profile.follower_count || 0} followers</span>
            <span>{profile.friend_count || data.friends?.length || 0} friends</span>
          </div>
        </div>
        {!isOwner ? <ProfileActions ctx={ctx} user={profile} onChanged={loadProfile} /> : null}
      </section>
      <section className="profile-sections">
        <div>
          <div className="section-head"><h2>Posts</h2><span>{data.media?.length || 0}</span></div>
          <MediaGrid ctx={ctx} items={data.media || []} emptyTitle="No public posts" />
        </div>
        <aside className="profile-rail">
          <div className="side-box"><h3>Collections</h3>{(data.collections || []).map((collection) => <CollectionMini collection={collection} key={collection.id} />)}{!data.collections?.length ? <p>No public collections.</p> : null}</div>
          <div className="side-box"><h3>Friends</h3>{(data.friends || []).map((friend) => <UserMini user={friend} key={friend.id} />)}{!data.friends?.length ? <p>No friends shown.</p> : null}</div>
        </aside>
      </section>
    </Page>
  );
}
