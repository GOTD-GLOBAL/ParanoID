package global.gotd.paranoid.identity.conformance

import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertTrue

class CommittedVectorContractTest {
    @Test
    fun selectedFixtureConstantsStillExistInCommittedJson() {
        val repositoryRoot = System.getProperty("paranoid.repo.root")
            ?: error("paranoid.repo.root is not configured")
        val vector = Files.readString(
            Path.of(
                repositoryRoot,
                "specs",
                "protocol",
                "identity",
                "key-derivation-experiment-v1.json",
            ),
        )

        assertContains(vector, PrototypeIdentityConformance.SCHEMA_VERSION)
        assertContains(vector, SelectedIdentityFixture.MNEMONIC)

        val candidateMarker = "\"candidate\": \"${PrototypeIdentityConformance.CANDIDATE}\""
        val candidateStart = vector.indexOf(candidateMarker)
        assertTrue(candidateStart >= 0, "committed vector is missing: $candidateMarker")
        val candidateEnd = vector.indexOf("\n    }", startIndex = candidateStart)
        assertTrue(candidateEnd > candidateStart, "selected candidate object is malformed")
        val candidateObject = vector.substring(candidateStart, candidateEnd)

        listOf(
            "\"mnemonic_word_count\": ${PrototypeIdentityConformance.MNEMONIC_WORD_COUNT}",
            "\"passphrase_used\": false",
            SelectedIdentityFixture.ACCOUNT_ROOT_PUBLIC_KEY_HEX,
            SelectedIdentityFixture.REGISTRY_AUTHORITY_PUBLIC_KEY_HEX,
        ).forEach { expected ->
            assertContains(candidateObject, expected)
        }
    }
}
