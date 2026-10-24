import getpass
from vault import PasswordVault
import secrets
import string
import pyperclip
import threading
import time


def clear_clipboard():
    time.sleep(15)
    pyperclip.copy("")
    print("\n[Clipboard cleared.]")


def generate_password(length=16):
    characters = string.ascii_letters + string.digits + string.punctuation
    password = "".join(secrets.choice(characters) for i in range(length))
    return password


def main():
    try:
        mp = getpass.getpass("Enter your master password: ")
        vault = PasswordVault(mp)
        print("\nVault unlocked successfully.")
    except ValueError as e:
        print(f"\n{e}")
        return

    while True:
        print("\n--- Secure Password Manager ---")
        print("1. Add a new password")
        print("2. Get a password")
        print("3. List all services")
        print("4. Delete a password")
        print("5. Generate a new secure password")
        print("6. Exit")

        choice = input("Choose an option: ")

        if choice == '1':
            service = input("Enter service name (e.g., gmail.com): ")
            passwd = getpass.getpass(f"Enter password for {service}: ")
            vault.add_password(service, passwd)

        elif choice == '2':
            service = input("Enter service name: ")
            try:
                passwd = vault.get_password(service)
                print(f"\nPassword for {service}: {passwd}")

                copy_choice = input("Copy to clipboard? (y/n): ").lower()
                if copy_choice == 'y':
                    pyperclip.copy(passwd)
                    print("\nPassword copied to clipboard. It will be cleared in 15 seconds.")
                    timer_thread = threading.Timer(1.0, clear_clipboard)
                    timer_thread.start()

            except ValueError as e:
                print(f"\nError: {e}")

        elif choice == '3':
            print("\nServices stored in vault:")
            vault.list_services()

        elif choice == '4':
            service = input("Enter service name to delete: ")
            vault.delete_password(service)

        elif choice == '5':
            print("\n--- Password Generator ---")
            try:
                length = int(input("Enter desired length (default 16): ") or "16")
                new_pass = generate_password(length)
                print(f"\nGenerated Password: {new_pass}")

                copy_choice = input("Copy to clipboard? (y/n): ").lower()
                if copy_choice == 'y':
                    pyperclip.copy(new_pass)
                    print("\nPassword copied to clipboard. It will be cleared in 15 seconds.")
                    timer_thread = threading.Timer(1.0, clear_clipboard)
                    timer_thread.start()
            except ValueError:
                print("Invalid length. Please enter a number.")

        elif choice == '6':
            print("Exiting.")
            break

        else:
            print("Invalid choice.")


if __name__ == "__main__":
    main()
