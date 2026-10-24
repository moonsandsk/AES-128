import json
import os
import getpass
import base64
from crypto_engine import CryptoEngine

VAULT_FILE = 'password_vault.json'


class PasswordVault:
    def __init__(self, master_password: str):
        self.vault_file = VAULT_FILE
        self._load_vault(master_password)

    def _load_vault(self, master_password: str):
        if os.path.exists(self.vault_file):
            with open(self.vault_file, 'r') as f:
                data = json.load(f)

            salt = base64.b64decode(data['master_salt'])
            self.engine = CryptoEngine(master_password, salt)
            self.entries = data['entries']

            if self.entries:
                try:
                    self.engine.decrypt(self.entries[0])
                except ValueError:
                    raise ValueError("Wrong master password.")
        else:
            print("Initializing new vault...")
            self.engine = CryptoEngine(master_password, salt=None)
            self.entries = []
            self.save_vault()

    def save_vault(self):
        data = {
            "master_salt": self.engine.get_master_salt_b64(),
            "entries": self.entries
        }
        with open(self.vault_file, 'w') as f:
            json.dump(data, f, indent=2)

    def add_password(self, service: str, password: str):
        if any(e['service'] == service for e in self.entries):
            print(f"Error: Service '{service}' already exists.")
            return

        print(f"Adding password for {service}...")
        encrypted_entry = self.engine.encrypt(password, service)
        self.entries.append(encrypted_entry)
        self.save_vault()
        print("Password added and vault saved.")

    def get_password(self, service: str) -> str:
        entry = next((e for e in self.entries if e['service'] == service), None)
        if not entry:
            raise ValueError(f"Service '{service}' not found.")

        return self.engine.decrypt(entry)

    def list_services(self):
        if not self.entries:
            print("[No entries in vault]")
            return
        for e in self.entries:
            print(f"- {e['service']}")

    def delete_password(self, service: str):
        entry = next((e for e in self.entries if e['service'] == service), None)
        if not entry:
            print(f"Error: Service '{service}' not found.")
            return

        self.entries.remove(entry)
        self.save_vault()
        print(f"Entry for '{service}' deleted.")
