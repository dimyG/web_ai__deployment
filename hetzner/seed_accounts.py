"""Create the superuser and the demo user. Idempotent: never rewrites an existing password.

Run with:  docker compose exec -T auth python manage.py shell < seed_accounts.py
"""
import os

from django.contrib.auth import get_user_model
from allauth.account.models import EmailAddress

User = get_user_model()


def ensure_user(email, password, is_superuser):
    # AUTH_USER_MODEL extends AbstractUser, so USERNAME_FIELD is 'username'. allauth's
    # ACCOUNT_AUTHENTICATION_METHOD = "username_email" lets people log in with either, so the
    # username is set to the email for consistency.
    existing = User.objects.filter(email__iexact=email).first()
    if existing is None:
        factory = User.objects.create_superuser if is_superuser else User.objects.create_user
        user = factory(username=email, email=email, password=password)
        action = "created"
    else:
        user = existing
        action = "already exists"

    # Without a verified EmailAddress row, allauth's email-based login path can fail even
    # though ACCOUNT_EMAIL_VERIFICATION is "none".
    EmailAddress.objects.update_or_create(
        user=user,
        email=email,
        defaults={"verified": True, "primary": True},
    )

    label = "superuser" if is_superuser else "demo user"
    print(f"{label}: {email} - {action} (id={user.pk}, tier={user.tier})")


ensure_user(os.environ["DJANGO_SUPERUSER_EMAIL"], os.environ["DJANGO_SUPERUSER_PASSWORD"], True)
ensure_user(os.environ["DEMO_USER_EMAIL"], os.environ["DEMO_USER_PASSWORD"], False)
