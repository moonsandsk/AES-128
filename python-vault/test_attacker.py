import json
import base64
from Crypto.Cipher import AES
from Crypto.Protocol.KDF import PBKDF2
from Crypto.Hash import SHA256
import binascii

WRONG_PASSWORD = "12345"
VAULT_FILE = 'password_vault.json'
PBKDF2_ITERATIONS = 600000

print(f"--- Attacker Simulation ---")
print(f"Trying to break into '{VAULT_FILE}' with password: '{WRONG_PASSWORD}'\n")

try:
    with open(VAULT_FILE, 'r') as f:
        data = json.load(f)

    salt = base64.b64decode(data['master_salt'])

    if not data['entries']:
        print("Test failed: Vault is empty. Add a password first and try again.")
        exit()

    entry = data['entries'][0]
    print(f"Found encrypted entry for: {entry['service']}")

    print("Deriving AES key using the *wrong* password...")
    attacker_key = PBKDF2(
        WRONG_PASSWORD,
        salt,
        dkLen=32,
        count=PBKDF2_ITERATIONS,
        hmac_hash_module=SHA256
    )
    print("Key derived.")

    print("Attempting decryption...")

    nonce = base64.b64decode(entry['nonce'])
    ciphertext = base64.b64decode(entry['ciphertext'])
    tag = base64.b64decode(entry['tag'])
    adata_bytes = entry['service'].encode('utf-8')

    cipher = AES.new(attacker_key, AES.MODE_GCM, nonce=nonce)
    cipher.update(adata_bytes)

    plaintext_bytes = cipher.decrypt_and_verify(ciphertext, tag)

    print("\n--- !!! ATTACK SUCCESSFUL !!! ---")
    print(f"Decrypted Data: {plaintext_bytes.decode('utf-8')}")

except (ValueError, KeyError, binascii.Error) as e:
    print("\n--- !!! ATTACK FAILED !!! ---")
    print(f"Decryption failed with error: {e}")
    print("\nThis is the *correct* behavior. The AES-GCM 'tag' check failed,")
    print("proving the attacker's key (from the wrong password) was invalid.")
