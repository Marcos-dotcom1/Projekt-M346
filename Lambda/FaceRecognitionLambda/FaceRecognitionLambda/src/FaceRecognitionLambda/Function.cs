using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Amazon.Lambda.Core;
using Amazon.Lambda.S3Events;
using Amazon.Rekognition;
using Amazon.Rekognition.Model;
using Amazon.S3;

// Damit Lambda das Event korrekt serialisiert / deserialisiert:
[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace FaceRecognitionLambda;

/// <summary>
/// Lambda-Funktion für die Erkennung bekannter Persönlichkeiten auf Bildern,
/// die in einen S3-Input-Bucket hochgeladen werden.
/// 
/// Ablauf:
/// 1. S3-Event löst Lambda aus, wenn ein neues Objekt hochgeladen wird.
/// 2. Rekognition (RecognizeCelebrities) wird aufgerufen.
/// 3. Ergebnis wird als JSON-Datei in einen Output-Bucket geschrieben.
/// 
/// Wichtige Voraussetzung:
/// - Environment Variable "OUTPUT_BUCKET" muss auf den Namen des Out-Buckets gesetzt sein.
///   (z.B. im Init-Script beim Deploy)
/// </summary>
public class Function
{
    private readonly IAmazonRekognition _rekognition;
    private readonly IAmazonS3 _s3;

    // Output-Bucket-Name aus Umgebungsvariable
    private readonly string _outputBucket;

    /// <summary>
    /// Standard-Konstruktor: wird von AWS Lambda verwendet.
    /// Erstellt Clients mit Default-Credentials (aus IAM-Rolle).
    /// </summary>
    public Function()
        : this(new AmazonRekognitionClient(), new AmazonS3Client())
    {
    }

    /// <summary>
    /// Konstruktor für Tests / Dependency Injection.
    /// </summary>
    public Function(IAmazonRekognition rekognitionClient, IAmazonS3 s3Client)
    {
        _rekognition = rekognitionClient;
        _s3 = s3Client;
        _outputBucket = Environment.GetEnvironmentVariable("OUTPUT_BUCKET") ?? string.Empty;
    }

    /// <summary>
    /// Haupteinstiegspunkt der Lambda-Funktion.
    /// Wird automatisch aufgerufen, wenn ein neues Objekt in den
    /// konfigurierten S3-Input-Bucket hochgeladen wird.
    /// </summary>
    /// <param name="s3Event">Das S3-Event mit Informationen zum hochgeladenen Objekt.</param>
    /// <param name="context">Lambda-Kontext (für Logging etc.).</param>
    public async Task FunctionHandler(S3Event s3Event, ILambdaContext context)
    {
        if (string.IsNullOrWhiteSpace(_outputBucket))
        {
            context.Logger.LogError("Environment variable OUTPUT_BUCKET is not set. Aborting.");
            return;
        }

        // Ein Event kann mehrere Records enthalten (Batch).
        foreach (var record in s3Event.Records)
        {
            var bucketName = record.S3.Bucket.Name;
            var objectKey = record.S3.Object.Key;

            context.Logger.LogInformation($"New image received: Bucket={bucketName}, Key={objectKey}");

            try
            {
                // 1. Rekognition für Celebrity-Erkennung aufrufen
                var request = new RecognizeCelebritiesRequest
                {
                    Image = new Image
                    {
                        S3Object = new Amazon.Rekognition.Model.S3Object
                        {
                            Bucket = bucketName,
                            Name = objectKey
                        }
                    }
                };

                var response = await _rekognition.RecognizeCelebritiesAsync(request);

                // 2. Ergebnis auf ein einfaches, gut lesbares Objekt mappen
                var result = new
                {
                    SourceImage = new
                    {
                        Bucket = bucketName,
                        Key = objectKey
                    },
                    Celebrities = response.CelebrityFaces.ConvertAll(c => new
                    {
                        c.Name,
                        c.MatchConfidence,
                        c.Id,
                        Urls = c.Urls,     // Links zu Infos über die erkannte Person
                    }),
                    UnrecognizedFaces = response.UnrecognizedFaces.Count,
                    OrientationCorrection = response.OrientationCorrection,
                    ProcessedAtUtc = DateTime.UtcNow
                };

                // 3. JSON formatieren
                var json = JsonSerializer.Serialize(
                    result,
                    new JsonSerializerOptions { WriteIndented = true }
                );

                // 4. Dateinamen für das Ergebnis bestimmen (gleicher Name, aber .json)
                var fileNameWithoutExtension = Path.GetFileNameWithoutExtension(objectKey);
                var outputKey = $"{fileNameWithoutExtension}.json";

                // 5. JSON in den Output-Bucket schreiben
                await _s3.PutObjectAsync(new Amazon.S3.Model.PutObjectRequest
                {
                    BucketName = _outputBucket,
                    Key = outputKey,
                    ContentBody = json,
                    ContentType = "application/json"
                });

                context.Logger.LogInformation(
                    $"Analysis successfully written to: Bucket={_outputBucket}, Key={outputKey}");
            }
            catch (Exception ex)
            {
                // Fehler werden geloggt, Lambda soll aber nicht komplett abstürzen
                context.Logger.LogError($"Error processing object {bucketName}/{objectKey}: {ex}");
            }
        }
    }
}
