import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';

class ImageHelper {
  static final ImagePicker _picker = ImagePicker();

  /// Pick an image from the gallery.
  /// Returns null if the user cancels.
  static Future<File?> pickImage() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (file == null) return null;
    return File(file.path);
  }

  /// Copy [image] into the app's permanent documents directory and
  /// return the saved path.
  ///
  /// FIX: the original code used basename(image.path) as the filename,
  /// which on most devices is a generic temp name like
  /// "image_picker_abc.jpg". Picking two images in the same second could
  /// produce the same basename, causing the second file to silently
  /// overwrite the first on disk.
  ///
  /// We now prefix with a microsecond timestamp, making collisions
  /// practically impossible even under rapid sequential picks.
  static Future<String> saveImage(File image) async {
    final directory = await getApplicationDocumentsDirectory();
    final ext       = p.extension(image.path).toLowerCase(); // e.g. ".jpg"
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final filename  = 'plant_img_$timestamp$ext';
    final dest      = p.join(directory.path, filename);
    final saved     = await image.copy(dest);
    return saved.path;
  }
}