library google_places_flutter;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_places_flutter/model/place_details.dart';
import 'package:google_places_flutter/model/prediction.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

typedef ItemClick = void Function(Prediction prediction);
typedef GetPlaceDetailsWithLatLng = void Function(Prediction prediction);

class GooglePlaceAutoCompleteTextField extends StatefulWidget {
  /// [InputDecoration] for the text field.
  final InputDecoration inputDecoration;

  /// Passes a [Prediction] when a prediction is clicked.
  final ItemClick? itemClick;

  /// Passes a [Prediction] with `LatLng` coordinates.
  final GetPlaceDetailsWithLatLng? getPlaceDetailWithLatLng;

  /// Optional parameter that determines if a [Prediction]
  /// will contain `LatLng` coordinates.
  ///
  /// Defaults to `true`
  final bool isLatLngRequired;

  /// [TextStyle] of the input text.
  final TextStyle textStyle;

  /// Google API Key gotten from the Google Cloud Console.
  /// (Ensure, Places API is enabled before using this key).
  final String googleAPIKey;

  /// Minimum interval before successive predictions call.
  ///
  /// Default is 600ms.
  final int debounceTime;

  /// Limit predictions to desired countries.
  final List<String>? countries;

  /// [TextEditingController] for this TextFormField.
  final TextEditingController textEditingController;

  /// Fine tune predictions results by defining search radius.
  ///
  /// Default is 500.
  final int radius;

  /// Latitude of the user's current location
  final double? latitude;

  /// Longitude of the user's current location
  final double? longitude;

  /// Optional parameter to determine finer search
  final bool strict;

  GooglePlaceAutoCompleteTextField({
    required this.textEditingController,
    required this.googleAPIKey,
    this.debounceTime = 600,
    this.inputDecoration: const InputDecoration(),
    this.itemClick,
    this.isLatLngRequired = true,
    this.textStyle: const TextStyle(),
    this.countries,
    this.getPlaceDetailWithLatLng,
    this.radius = 500,
    this.latitude,
    this.longitude,
    this.strict = false,
  });

  @override
  _GooglePlaceAutoCompleteTextFieldState createState() =>
      _GooglePlaceAutoCompleteTextFieldState();
}

class _GooglePlaceAutoCompleteTextFieldState
    extends State<GooglePlaceAutoCompleteTextField> {
  final _subject = PublishSubject<String>();
  OverlayEntry? _overlayEntry;
  List<Prediction> _allPredictions = [];

  final LayerLink _layerLink = LayerLink();

  /// Session token that generates at the beginning of every prediction search
  /// and regenerates when a prediction has been selected.
  String _sessionToken = Uuid().v4();

  static const String _baseUrl = 'https://maps.googleapis.com/maps/api/place';
  final Dio _dio = Dio()..options.baseUrl = _baseUrl;

  @override
  void initState() {
    _subject.stream
        .distinct()
        .debounceTime(Duration(milliseconds: widget.debounceTime))
        .listen(_getLocation);

    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(
          responseBody: true,
          error: true,
          requestHeader: true,
          responseHeader: true,
          request: true,
          requestBody: true,
          logPrint: (text) {
            final pattern = RegExp('.{1,800}');
            pattern
                .allMatches(text.toString())
                .forEach((match) => debugPrint(match.group(0)));
          },
        ),
      );
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextFormField(
        decoration: widget.inputDecoration,
        style: widget.textStyle,
        controller: widget.textEditingController,
        onChanged: (string) => (_subject.add(string)),
      ),
    );
  }

  OverlayEntry? _createOverlayEntry() {
    if (context.findRenderObject() != null) {
      RenderBox renderBox = context.findRenderObject() as RenderBox;
      var size = renderBox.size;
      var offset = renderBox.localToGlobal(Offset.zero);
      return OverlayEntry(
        builder: (context) => Positioned(
          left: offset.dx,
          top: size.height + offset.dy,
          width: size.width,
          child: CompositedTransformFollower(
            showWhenUnlinked: false,
            link: this._layerLink,
            offset: Offset(0.0, size.height + 5.0),
            child: Material(
              elevation: 1.0,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: _allPredictions.length,
                itemBuilder: (BuildContext context, int index) {
                  return InkWell(
                    onTap: () {
                      if (index < _allPredictions.length) {
                        widget.itemClick!(_allPredictions[index]);
                        if (widget.isLatLngRequired) {
                          _getPlaceDetailsFromPlaceId(_allPredictions[index]);
                        }

                        _removeOverlay();
                        _sessionToken = Uuid().v4();
                      }
                    },
                    child: Container(
                      padding: EdgeInsets.all(10),
                      child: Text(_allPredictions[index].description!),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }
    return null;
  }

  void _removeOverlay() {
    _allPredictions.clear();
    this._overlayEntry = this._createOverlayEntry();
    Overlay.of(context)!.insert(this._overlayEntry!);
    this._overlayEntry!.markNeedsBuild();
  }

  Future<void> _getLocation(String text) async {
    String url =
        '$_baseUrl/autocomplete/json?input=$text&radius=${widget.radius}'
        '&sessiontoken=$_sessionToken&strictbounds=${widget.strict}'
        '&key=${widget.googleAPIKey}';

    if (widget.countries != null) {
      for (int i = 0; i < widget.countries!.length; i++) {
        String country = widget.countries![i];

        if (i == 0) {
          url += '&components=country:$country';
        } else {
          url += '|country:$country';
        }
      }
    }

    if (widget.latitude != null && widget.longitude != null) {
      assert(
        (widget.latitude != 0.0 && widget.longitude != 0.0),
        'Latitude & Longitude cannot be 0.0',
      );
      final lat = widget.latitude;
      final lng = widget.longitude;

      url += '&location=$lat%2C$lng';
    }

    Response response = await _dio.get(url);
    PlacesAutocompleteResponse subscriptionResponse =
        PlacesAutocompleteResponse.fromJson(response.data);

    if (text.length == 0) {
      _allPredictions.clear();
      this._overlayEntry!.remove();
      return;
    }

    if (subscriptionResponse.predictions!.length > 0) {
      _allPredictions.clear();
      _allPredictions.addAll(subscriptionResponse.predictions!);
    }

    this._overlayEntry = null;
    this._overlayEntry = this._createOverlayEntry();
    Overlay.of(context)!.insert(this._overlayEntry!);
  }

  Future<void> _getPlaceDetailsFromPlaceId(Prediction prediction) async {
    var url = '$_baseUrl/details/json?placeid=${prediction.placeId}'
        '&sessiontoken=$_sessionToken&key=${widget.googleAPIKey}';

    Response response = await Dio().get(url);

    PlaceDetails placeDetails = PlaceDetails.fromJson(response.data);

    prediction.lat = placeDetails.result!.geometry!.location!.lat.toString();
    prediction.lng = placeDetails.result!.geometry!.location!.lng.toString();

    widget.getPlaceDetailWithLatLng!(prediction);
  }
}
