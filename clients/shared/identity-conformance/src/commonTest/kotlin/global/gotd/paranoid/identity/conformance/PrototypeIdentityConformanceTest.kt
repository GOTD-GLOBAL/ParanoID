package global.gotd.paranoid.identity.conformance

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals

class PrototypeIdentityConformanceTest {
    @Test
    fun selectedRustVectorIsReproduced() {
        val actual = PrototypeIdentityConformance.derivePublicAuthorities(
            SelectedIdentityFixture.MNEMONIC,
            SelectedIdentityFixture.PASSPHRASE,
        )

        assertEquals(
            SelectedIdentityFixture.ACCOUNT_ROOT_PUBLIC_KEY_HEX,
            actual.accountRootPublicKeyHex,
        )
        assertEquals(
            SelectedIdentityFixture.REGISTRY_AUTHORITY_PUBLIC_KEY_HEX,
            actual.registryAuthorityPublicKeyHex,
        )
    }

    @Test
    fun derivationIsDeterministicAndPurposeSeparated() {
        val first = PrototypeIdentityConformance.derivePublicAuthorities(
            SelectedIdentityFixture.MNEMONIC,
        )
        val second = PrototypeIdentityConformance.derivePublicAuthorities(
            SelectedIdentityFixture.MNEMONIC,
        )

        assertEquals(first, second)
        assertNotEquals(first.accountRootPublicKeyHex, first.registryAuthorityPublicKeyHex)
    }

    @Test
    fun nonEmptyPassphraseIsRejectedByPrototypePolicy() {
        assertFailsWith<IllegalArgumentException> {
            PrototypeIdentityConformance.derivePublicAuthorities(
                SelectedIdentityFixture.MNEMONIC,
                "not-enabled-in-v1",
            )
        }
    }

    @Test
    fun malformedMnemonicShapesAreRejected() {
        val malformed = listOf(
            SelectedIdentityFixture.MNEMONIC.substringBeforeLast(' '),
            SelectedIdentityFixture.MNEMONIC.uppercase(),
            " ${SelectedIdentityFixture.MNEMONIC}",
            SelectedIdentityFixture.MNEMONIC.replaceFirst(" ", "  "),
        )

        malformed.forEach { mnemonic ->
            assertFailsWith<IllegalArgumentException> {
                PrototypeIdentityConformance.derivePublicAuthorities(mnemonic)
            }
        }
    }
}
