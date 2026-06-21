// lib/services/guest_session.dart
//
// Singleton que indica si el usuario está navegando como invitado.
// No persiste entre reinicios de la app: el invitado siempre debe
// volver a elegir al abrir la app de nuevo.

class GuestSession {
  GuestSession._();
  static final GuestSession _instance = GuestSession._();
  factory GuestSession() => _instance;

  bool _isGuest = false;

  /// true si el usuario entró sin cuenta.
  bool get isGuest => _isGuest;

  /// Activa el modo invitado.
  void startGuestSession() => _isGuest = true;

  /// Limpia el modo invitado (al hacer logout o cerrar sesión de invitado).
  void clearGuestSession() => _isGuest = false;
}
