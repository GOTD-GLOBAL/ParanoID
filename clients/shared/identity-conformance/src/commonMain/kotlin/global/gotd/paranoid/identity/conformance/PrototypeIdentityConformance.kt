package global.gotd.paranoid.identity.conformance

import dev.whyoleg.cryptography.BinarySize.Companion.bits
import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.algorithms.EdDSA
import dev.whyoleg.cryptography.algorithms.HKDF
import dev.whyoleg.cryptography.algorithms.PBKDF2
import dev.whyoleg.cryptography.algorithms.SHA512

/** Public authorities produced by the experimental mobile conformance code. */
public data class PrototypePublicAuthorities(
    /** Hex-encoded Ed25519 account-root public key. */
    public val accountRootPublicKeyHex: String,
    /** Hex-encoded Ed25519 Solana-registry-authority public key. */
    public val registryAuthorityPublicKeyHex: String,
)

/**
 * Reproduces the provisional HKDF candidate from `EXP-IDENTITY-0001`.
 *
 * This object accepts only the narrow prototype policy: 24 lowercase English
 * words separated by single ASCII spaces and an empty passphrase. It validates
 * shape, not the BIP-39 word list or checksum, and is not production account
 * creation code.
 */
public object PrototypeIdentityConformance {
    /** Public experiment schema implemented by this spike. */
    public const val SCHEMA_VERSION: String = "paranoid.identity.key-hierarchy.experiment.v1"

    /** Provisional candidate selected for cross-platform evaluation. */
    public const val CANDIDATE: String = "hkdf_sha512_v1"

    /** Word count used by the prototype-only mnemonic policy. */
    public const val MNEMONIC_WORD_COUNT: Int = 24

    private const val BIP39_ITERATIONS: Int = 2_048
    private const val BIP39_SALT_PREFIX: String = "mnemonic"
    private const val EXPERIMENT_SALT: String =
        "ParanoID identity-core key hierarchy experiment v1"
    private const val ACCOUNT_ROOT_INFO: String =
        "paranoid.identity.experiment.v1/account-root/ed25519-seed"
    private const val REGISTRY_AUTHORITY_INFO: String =
        "paranoid.identity.experiment.v1/solana-registry-authority/ed25519-seed"

    /**
     * Derives public authorities for the prototype-only canonical mnemonic.
     *
     * The input mnemonic remains owned by the caller. This function clears its
     * mutable intermediate byte arrays on a best-effort basis before returning.
     */
    public fun derivePublicAuthorities(
        mnemonic: String,
        passphrase: String = "",
    ): PrototypePublicAuthorities {
        requirePrototypeInput(mnemonic, passphrase)

        val provider = CryptographyProvider.Default
        val bip39Seed = provider.get(PBKDF2).secretDerivation(
            digest = SHA512,
            iterations = BIP39_ITERATIONS,
            outputSize = 512.bits,
            salt = (BIP39_SALT_PREFIX + passphrase).encodeToByteArray(),
        ).deriveSecretToByteArrayBlocking(mnemonic.encodeToByteArray())

        return try {
            val accountRootSeed = derivePurposeSeed(provider, bip39Seed, ACCOUNT_ROOT_INFO)
            try {
                val registryAuthoritySeed =
                    derivePurposeSeed(provider, bip39Seed, REGISTRY_AUTHORITY_INFO)
                try {
                    PrototypePublicAuthorities(
                        accountRootPublicKeyHex = publicKeyHex(provider, accountRootSeed),
                        registryAuthorityPublicKeyHex =
                            publicKeyHex(provider, registryAuthoritySeed),
                    )
                } finally {
                    registryAuthoritySeed.fill(0)
                }
            } finally {
                accountRootSeed.fill(0)
            }
        } finally {
            bip39Seed.fill(0)
        }
    }

    private fun requirePrototypeInput(mnemonic: String, passphrase: String) {
        require(passphrase.isEmpty()) {
            "the prototype policy does not accept a BIP-39 passphrase"
        }

        val words = mnemonic.split(' ')
        require(words.size == MNEMONIC_WORD_COUNT) {
            "the prototype policy requires exactly $MNEMONIC_WORD_COUNT words"
        }
        require(words.all { word -> word.isNotEmpty() && word.all { it in 'a'..'z' } }) {
            "the prototype mnemonic must use lowercase ASCII words and single spaces"
        }
        require(words.joinToString(" ") == mnemonic) {
            "the prototype mnemonic must use one ASCII space between words"
        }
    }

    private fun derivePurposeSeed(
        provider: CryptographyProvider,
        bip39Seed: ByteArray,
        info: String,
    ): ByteArray = provider.get(HKDF).secretDerivation(
        digest = SHA512,
        outputSize = 256.bits,
        salt = EXPERIMENT_SALT.encodeToByteArray(),
        info = info.encodeToByteArray(),
    ).deriveSecretToByteArrayBlocking(bip39Seed)

    private fun publicKeyHex(provider: CryptographyProvider, privateSeed: ByteArray): String {
        val ed25519 = provider.get(EdDSA)
        val privateKey = ed25519.privateKeyDecoder(EdDSA.Curve.Ed25519)
            .decodeFromByteArrayBlocking(EdDSA.PrivateKey.Format.RAW, privateSeed)
        val publicKey = privateKey.getPublicKeyBlocking()
            .encodeToByteArrayBlocking(EdDSA.PublicKey.Format.RAW)
        return publicKey.toHex()
    }

    private fun ByteArray.toHex(): String = joinToString(separator = "") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}
