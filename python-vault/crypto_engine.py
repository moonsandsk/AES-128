import os
import json
import base64
import binascii
from Crypto.Cipher import AES
from Crypto.Protocol.KDF import PBKDF2
from Crypto.Hash import SHA256
from Crypto.Random import get_random_bytes

PBKDF2_ITERATIONS = 600000


class CryptoEngine:
    def __init__(self, master_password: str, salt: bytes = None):
        if salt is None:
            self.salt = get_random_bytes(16)
        else:
            self.salt = salt

        self.key = PBKDF2(
            master_password,
            self.salt,
            dkLen=32,
            count=PBKDF2_ITERATIONS,
            hmac_hash_module=SHA256
        )

    def get_master_salt_b64(self) -> str:
        return base64.b64encode(self.salt).decode('utf-8')

    def encrypt(self, plaintext: str, associated_data: str) -> dict:
        plaintext_bytes = plaintext.encode('utf-8')
        adata_bytes = associated_data.encode('utf-8')

        cipher = AES.new(self.key, AES.MODE_GCM)
        cipher.update(adata_bytes)
        ciphertext, tag = cipher.encrypt_and_digest(plaintext_bytes)

        return {
            "service": associated_data,
            "nonce": base64.b64encode(cipher.nonce).decode('utf-8'),
            "ciphertext": base64.b64encode(ciphertext).decode('utf-8'),
            "tag": base64.b64encode(tag).decode('utf-8')
        }

    def decrypt(self, entry: dict) -> str:
        try:
            nonce = base64.b64decode(entry['nonce'])
            ciphertext = base64.b64decode(entry['ciphertext'])
            tag = base64.b64decode(entry['tag'])
            adata_bytes = entry['service'].encode('utf-8')

            cipher = AES.new(self.key, AES.MODE_GCM, nonce=nonce)
            cipher.update(adata_bytes)

            plaintext_bytes = cipher.decrypt_and_verify(ciphertext, tag)
            return plaintext_bytes.decode('utf-8')

        except (ValueError, KeyError, binascii.Error) as e:
            print(f"Decryption failed! Error: {e}")
            raise ValueError("Decryption failed: Wrong master password or corrupted data.")
