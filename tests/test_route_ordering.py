from __future__ import annotations

import app.main as main


def _route_index(path: str, method: str) -> int:
    """Index of the first route matching path+method in registration order.

    Registration order is what Starlette actually matches against — a dynamic
    path template registered before a static one that could also match the
    same request will silently (or, for typed params, loudly with a 422)
    swallow it. This guards the three such pairs found in this codebase.
    """
    method = method.upper()
    for index, route in enumerate(main.app.routes):
        if getattr(route, "path", None) == path and method in (getattr(route, "methods", None) or ()):
            return index
    raise AssertionError(f"No route registered for {method} {path}")


def test_users_search_registered_before_username_param() -> None:
    # /api/users/{username} has an untyped str param, so a reorder here fails
    # SILENTLY (it would just look up a real user literally named "search")
    # rather than erroring — the most dangerous of the three pairs.
    assert _route_index("/api/users/search", "GET") < _route_index("/api/users/{username}", "GET")


def test_media_random_registered_before_media_id_param() -> None:
    assert _route_index("/api/media/random", "GET") < _route_index("/api/media/{media_id}", "GET")


def test_messages_threads_registered_before_user_id_param() -> None:
    assert _route_index("/api/messages/threads", "GET") < _route_index("/api/messages/{user_id}", "GET")


def test_media_trending_registered_before_media_id_param() -> None:
    assert _route_index("/api/media/trending", "GET") < _route_index("/api/media/{media_id}", "GET")


def test_collections_suggestions_registered_before_collection_id_param() -> None:
    assert _route_index("/api/collections/suggestions", "GET") < _route_index("/api/collections/{collection_id}", "GET")
