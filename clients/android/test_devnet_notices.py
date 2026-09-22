"""The integrated APK must attribute both locked Rust dependency closures."""
from pathlib import Path
import subprocess
import unittest
R=Path(__file__).resolve().parent
class Notices(unittest.TestCase):
 def test_devnet_crypto_is_in_notices(self):
  subprocess.run(['python3',str(R/'notices.py')],cwd=R,check=True)
  text=(R/'out/THIRD_PARTY_NOTICES.txt').read_text()
  for name in ['solana-address 2.6.1','ed25519-dalek-bip32 0.3.0','bip39 3.0.0','vodozemac','Firebase Cloud Messaging closure','WebRTC SDK']:
   self.assertIn(name,text)
if __name__=='__main__':unittest.main()
