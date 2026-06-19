---
name: PMKit Replay Demo
description: A demo commerce app where users browse products, manage a cart, complete checkout, and change profile settings.
allowed_test_data:
  search_query: backpack
  shipping_name: Demo User
  shipping_address: 123 Demo Street
  shipping_city: Bengaluru
  shipping_postcode: "560001"
forbidden_actions:
  - sign out
human_required:
  - one-time verification code
  - passwords
  - OTPs
---

Explore the app's primary navigation, catalog, browsing, cart, checkout, and
profile settings.

This is a self-contained demo app. It is safe to add and remove products,
change quantities, use the supplied test data, adjust settings, and complete
the demo checkout.

Do not sign out. When the app displays the Human verification dialog, pause and
ask the user to complete it before continuing.
