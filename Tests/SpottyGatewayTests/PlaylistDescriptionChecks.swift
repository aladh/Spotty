import Testing
@testable import SpottyGateway

struct PlaylistDescriptionTests {
    @Test func escapedEntitiesAreDecodedOnlyOnce() {
        #expect(
            PlaylistDescription.plainText(
                from: "&amp;nbsp; &amp;amp; &amp;quot; &amp;#39; &amp;apos; &amp;lt; &amp;gt;"
            ) == "&nbsp; &amp; &quot; &#39; &apos; &lt; &gt;")
    }

    @Test func tagsLineBreaksAndSupportedEntitiesKeepTheirDisplayFormatting() {
        #expect(
            PlaylistDescription.plainText(
                from: """
                     <p>&quot;First&nbsp;&amp; Second&quot;</p>
                    <div>Artist&#39;s <a href="spotify:artist:fixture">mix</a><BR />
                      &apos;Next&apos; &lt;track&gt;</div>
                    """
            ) == "\"First & Second\"\nArtist's mix\n'Next' <track>")
    }

    @Test func escapedTagsAndUnsupportedEntitiesRemainText() {
        #expect(
            PlaylistDescription.plainText(
                from: "&lt;b&gt;literal&lt;/b&gt; &copy; &#169; &#xA9; &AMP; &amp;unknown;"
            ) == "<b>literal</b> &copy; &#169; &#xA9; &AMP; &unknown;")
    }
}
