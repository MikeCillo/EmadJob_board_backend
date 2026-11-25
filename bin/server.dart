import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

final _dataDir = Directory('data');
final _uploadsDir = Directory('uploads');
final _dbFile = File('data/db.json');

Map<String, dynamic> _db = {
  'companies': [],
  'jobs': [],
  'applications': [],
  'tokens': {},
};

void _initStorage() {
  if (!_dataDir.existsSync()) _dataDir.createSync(recursive: true);
  if (!_uploadsDir.existsSync()) _uploadsDir.createSync(recursive: true);

  if (_dbFile.existsSync()) {
    final content = _dbFile.readAsStringSync();
    if (content.trim().isNotEmpty) {
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      _db = {
        'companies': List.from(decoded['companies'] ?? []),
        'jobs': List.from(decoded['jobs'] ?? []),
        'applications': List.from(decoded['applications'] ?? []),
        'tokens': Map.from(decoded['tokens'] ?? {}),
      };
    }
  } else {
    _saveDb();
  }
}

void _saveDb() {
  _dbFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_db));
}

String _hashPassword(String password) {
  return sha256.convert(utf8.encode(password)).toString();
}

String _generateId() {
  final rnd = Random.secure();
  final bytes = List.generate(12, (_) => rnd.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Response _jsonResponse(Object data, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(data),
    headers: {'Content-Type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic>? _getAuthenticatedCompany(Request request) {
  final authHeader = request.headers['authorization'];
  if (authHeader == null || !authHeader.startsWith('Bearer ')) return null;
  final token = authHeader.substring(7).trim();
  final tokens = _db['tokens'] as Map;
  final companyId = tokens[token];
  if (companyId == null) return null;

  final companies = _db['companies'] as List;
  for (final c in companies) {
    if (c['id'] == companyId) return Map<String, dynamic>.from(c);
  }
  return null;
}

Middleware _corsMiddleware() {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
  };

  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }
      final response = await innerHandler(request);
      return response.change(headers: corsHeaders);
    };
  };
}

// R1 – Registrazione azienda
Future<Response> _registerHandler(Request request) async {
  try {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final companyName = (body['companyName'] ?? '').toString().trim();
    final email = (body['email'] ?? '').toString().trim().toLowerCase();
    final password = (body['password'] ?? '').toString();

    if (companyName.isEmpty || email.isEmpty || password.length < 4) {
      return _jsonResponse(
        {'error': 'Inserisci nome azienda, email valida e password (min 4 caratteri).'},
        statusCode: 400,
      );
    }

    final companies = _db['companies'] as List;
    if (companies.any((c) => c['email'] == email)) {
      return _jsonResponse({'error': 'Email già registrata.'}, statusCode: 409);
    }

    final company = {
      'id': _generateId(),
      'companyName': companyName,
      'email': email,
      'passwordHash': _hashPassword(password),
    };

    companies.add(company);
    _saveDb();

    return _jsonResponse({
      'message': 'Registrazione completata.',
      'company': {
        'id': company['id'],
        'companyName': company['companyName'],
        'email': company['email'],
      },
    }, statusCode: 201);
  } catch (e) {
    return _jsonResponse({'error': 'Richiesta non valida.'}, statusCode: 400);
  }
}

// R2 – Login azienda
Future<Response> _loginHandler(Request request) async {
  try {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] ?? '').toString().trim().toLowerCase();
    final password = (body['password'] ?? '').toString();
    final hash = _hashPassword(password);

    final companies = _db['companies'] as List;
    Map<String, dynamic>? found;
    for (final c in companies) {
      if (c['email'] == email && c['passwordHash'] == hash) {
        found = Map<String, dynamic>.from(c);
        break;
      }
    }

    if (found == null) {
      return _jsonResponse({'error': 'Email o password errati.'}, statusCode: 401);
    }

    final token = _generateId() + _generateId();
    (_db['tokens'] as Map)[token] = found['id'];
    _saveDb();

    return _jsonResponse({
      'token': token,
      'company': {
        'id': found['id'],
        'companyName': found['companyName'],
        'email': found['email'],
      },
    });
  } catch (e) {
    return _jsonResponse({'error': 'Richiesta non valida.'}, statusCode: 400);
  }
}

// R3 – Logout azienda
Future<Response> _logoutHandler(Request request) async {
  final authHeader = request.headers['authorization'];
  if (authHeader != null && authHeader.startsWith('Bearer ')) {
    final token = authHeader.substring(7).trim();
    (_db['tokens'] as Map).remove(token);
    _saveDb();
  }
  return _jsonResponse({'message': 'Logout effettuato.'});
}

// R5 – Elenco pubblico di tutti gli annunci
Response _getJobsHandler(Request request) {
  final jobs = _db['jobs'] as List;
  final sorted = List.from(jobs.reversed);
  return _jsonResponse(sorted);
}

// R4 – Pubblicazione nuovo annuncio (solo azienda autenticata)
Future<Response> _createJobHandler(Request request) async {
  final company = _getAuthenticatedCompany(request);
  if (company == null) {
    return _jsonResponse({'error': 'Non autenticato.'}, statusCode: 401);
  }

  try {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final title = (body['title'] ?? '').toString().trim();
    final description = (body['description'] ?? '').toString().trim();

    if (title.isEmpty || description.isEmpty) {
      return _jsonResponse(
        {'error': 'Titolo e descrizione sono obbligatori.'},
        statusCode: 400,
      );
    }

    final job = {
      'id': _generateId(),
      'companyId': company['id'],
      'companyName': company['companyName'],
      'title': title,
      'description': description,
      'createdAt': DateTime.now().toIso8601String(),
    };

    (_db['jobs'] as List).add(job);
    _saveDb();

    return _jsonResponse(job, statusCode: 201);
  } catch (e) {
    return _jsonResponse({'error': 'Richiesta non valida.'}, statusCode: 400);
  }
}

// R7 – Elenco annunci dell'azienda autenticata (con conteggio candidature)
Response _getMyJobsHandler(Request request) {
  final company = _getAuthenticatedCompany(request);
  if (company == null) {
    return _jsonResponse({'error': 'Non autenticato.'}, statusCode: 401);
  }

  final jobs = _db['jobs'] as List;
  final apps = _db['applications'] as List;

  final myJobs = jobs
      .where((j) => j['companyId'] == company['id'])
      .map((j) {
        final count = apps.where((a) => a['jobId'] == j['id']).length;
        return {...Map<String, dynamic>.from(j), 'applicationsCount': count};
      })
      .toList()
      .reversed
      .toList();

  return _jsonResponse(myJobs);
}

// R6 – Candidatura a un annuncio (con salvataggio del PDF su disco)
Future<Response> _applyToJobHandler(Request request, String jobId) async {
  final jobs = _db['jobs'] as List;
  if (!jobs.any((j) => j['id'] == jobId)) {
    return _jsonResponse({'error': 'Annuncio non trovato.'}, statusCode: 404);
  }

  try {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final firstName = (body['firstName'] ?? '').toString().trim();
    final lastName = (body['lastName'] ?? '').toString().trim();
    final email = (body['email'] ?? '').toString().trim();
    final cvFileName = (body['cvFileName'] ?? 'curriculum.pdf').toString().trim();
    final cvBase64 = (body['cvBase64'] ?? '').toString();

    if (firstName.isEmpty || lastName.isEmpty || email.isEmpty || cvBase64.isEmpty) {
      return _jsonResponse(
        {'error': 'Compila tutti i campi e allega il curriculum.'},
        statusCode: 400,
      );
    }

    final safeName = cvFileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final storedFileName = '${_generateId()}_$safeName';
    final fileBytes = base64Decode(cvBase64);
    await File('uploads/$storedFileName').writeAsBytes(fileBytes);

    final application = {
      'id': _generateId(),
      'jobId': jobId,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'cvFileName': cvFileName,
      'cvUrl': '/uploads/$storedFileName',
      'createdAt': DateTime.now().toIso8601String(),
    };

    (_db['applications'] as List).add(application);
    _saveDb();

    return _jsonResponse(application, statusCode: 201);
  } catch (e) {
    return _jsonResponse({'error': 'Errore nel salvataggio candidatura.'}, statusCode: 400);
  }
}

// R7 – Candidature ricevute per un annuncio (solo azienda proprietaria)
Response _getJobApplicationsHandler(Request request, String jobId) {
  final company = _getAuthenticatedCompany(request);
  if (company == null) {
    return _jsonResponse({'error': 'Non autenticato.'}, statusCode: 401);
  }

  final jobs = _db['jobs'] as List;
  final jobExistsForCompany =
      jobs.any((j) => j['id'] == jobId && j['companyId'] == company['id']);

  if (!jobExistsForCompany) {
    return _jsonResponse({'error': 'Annuncio non trovato o non autorizzato.'}, statusCode: 403);
  }

  final apps = _db['applications'] as List;
  final jobApps = apps.where((a) => a['jobId'] == jobId).toList().reversed.toList();
  return _jsonResponse(jobApps);
}

// R7 – Download/apertura del curriculum PDF salvato sul server
Future<Response> _serveUploadHandler(Request request, String filename) async {
  if (filename.contains('..') || filename.contains('/')) {
    return Response.forbidden('Accesso negato.');
  }
  final file = File('uploads/$filename');
  if (!await file.exists()) {
    return Response.notFound('File non trovato.');
  }

  final bytes = await file.readAsBytes();
  final contentType = filename.toLowerCase().endsWith('.pdf')
      ? 'application/pdf'
      : 'application/octet-stream';

  return Response.ok(
    bytes,
    headers: {
      'Content-Type': contentType,
      'Content-Disposition': 'inline; filename="$filename"',
    },
  );
}

void main() async {
  _initStorage();

  final router = Router()
    ..post('/auth/register', _registerHandler)
    ..post('/auth/login', _loginHandler)
    ..post('/auth/logout', _logoutHandler)
    ..get('/jobs', _getJobsHandler)
    ..post('/jobs', _createJobHandler)
    ..get('/my-jobs', _getMyJobsHandler)
    ..post('/jobs/<jobId>/apply', _applyToJobHandler)
    ..get('/jobs/<jobId>/applications', _getJobApplicationsHandler)
    ..get('/uploads/<filename>', _serveUploadHandler);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(router.call);

  final server = await serve(handler, InternetAddress.anyIPv4, 8080);
  print('Server avviato su http://${server.address.host}:${server.port}');
}
