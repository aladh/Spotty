use super::SpotifyUri;

/// Preserve protocol URI forms; normalize only resource URLs belonging to Spotify.
pub(crate) fn url_to_uri(input: &str) -> Option<String> {
    // Librespot also supports named, collection, search, and local URI forms.
    if let Some((scheme, uri)) = input.split_once(':')
        && scheme.eq_ignore_ascii_case("spotify")
    {
        return Some(format!("spotify:{uri}"));
    }

    // HTTP URI parsing separates authority, path, and query. Browser fragments are
    // not sent to a server and do not identify a different Spotify resource.
    let without_fragment = input.split_once('#').map_or(input, |(url, _)| url);
    let url: http::Uri = without_fragment.parse().ok()?;
    if !matches!(url.scheme_str(), Some("http" | "https"))
        || !url
            .authority()?
            .as_str()
            .eq_ignore_ascii_case("open.spotify.com")
    {
        return None;
    }

    let path = url.path().strip_prefix('/')?;
    let mut parts = path.strip_suffix('/').unwrap_or(path).split('/');
    let first = parts.next()?;
    let content_type = if let Some(locale) = first.strip_prefix("intl-") {
        if !locale
            .split('-')
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_alphanumeric()))
        {
            return None;
        }
        parts.next()?
    } else {
        first
    };
    let id = parts.next()?;
    if parts.next().is_some()
        || !matches!(
            content_type,
            "track" | "album" | "artist" | "playlist" | "episode" | "show"
        )
        || id.is_empty()
        || !id.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        return None;
    }

    let uri = format!("spotify:{content_type}:{id}");
    SpotifyUri::from_uri(&uri).ok()?;
    Some(uri)
}

// Helper function to parse Spotify URI from string
pub(crate) fn parse_spotify_uri(uri_str: &str) -> Result<SpotifyUri, String> {
    SpotifyUri::from_uri(uri_str).map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}
