#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// -------------------- SISTEMA DE LOG --------------------
// Função para registrar logs no arquivo
static void vcam_log(NSString *message) {
    static dispatch_queue_t logQueue = nil;
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        // Cria uma fila dedicada para operações de log
        logQueue = dispatch_queue_create("com.vcam.log", DISPATCH_QUEUE_SERIAL);
        
        // Inicializa o formatador de data
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    });
    
    dispatch_async(logQueue, ^{
        // Obtém a data e hora atual
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
        
        // Formata a mensagem de log com timestamp
        NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        // Caminho para o arquivo de log
        NSString *logPath = @"/tmp/vcam_debug.log";
        
        // Verifica se o arquivo existe, se não, cria-o
        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
            [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        // Abre o arquivo em modo de anexação
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        }
    });
}

// Função para registrar logs com formato, semelhante a NSLog
static void vcam_logf(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // Usa a função vcam_log para registrar a mensagem formatada
    vcam_log(message);
}
// -------------------- FIM DO SISTEMA DE LOG --------------------

// Variáveis globais para gerenciamento de recursos
static NSFileManager *g_fileManager = nil;                 // Objeto para gerenciamento de arquivos
static BOOL g_canReleaseBuffer = YES;                      // Flag que indica se o buffer pode ser liberado
static BOOL g_bufferReload = YES;                          // Flag que indica se o vídeo precisa ser recarregado
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // Timestamp da última atualização por VideoDataOutput
static BOOL g_cameraRunning = NO;                          // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B";                  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait; // Última orientação para otimização

// Caminho do arquivo de vídeo padrão
static NSString *const g_videoFile = @"/tmp/default.mp4";

// Classe para obtenção e manipulação de frames de vídeo
@interface GetFrame : NSObject
+ (instancetype)sharedInstance;
- (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer forceReNew:(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
@end

@implementation GetFrame {
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_videoTrackout_32BGRA;
    AVAssetReaderTrackOutput *_videoTrackout_420YpCbCr8BiPlanarVideoRange;
    AVAssetReaderTrackOutput *_videoTrackout_420YpCbCr8BiPlanarFullRange;
    CMSampleBufferRef _sampleBuffer;
    dispatch_queue_t _processingQueue;
    AVAsset *_videoAsset;
}

// Implementação Singleton
+ (instancetype)sharedInstance {
    static GetFrame *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _processingQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        _reader = nil;
        _videoTrackout_32BGRA = nil;
        _videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
        _videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
        _sampleBuffer = nil;
        _videoAsset = nil;
    }
    return self;
}

- (void)dealloc {
    [self releaseResources];
}

- (void)releaseResources {
    if (_sampleBuffer != nil) {
        CFRelease(_sampleBuffer);
        _sampleBuffer = nil;
    }
    
    _reader = nil;
    _videoTrackout_32BGRA = nil;
    _videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
    _videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
    _videoAsset = nil;
}

// Método para configurar o leitor de vídeo
- (BOOL)setupVideoReader {
    @try {
        // Verificamos se existe um arquivo de vídeo para substituição
        if (![g_fileManager fileExistsAtPath:g_videoFile]) {
            vcam_log(@"Arquivo de vídeo para substituição não encontrado");
            return NO;
        }
        
        // Criamos um AVAsset a partir do arquivo de vídeo
        NSURL *videoURL = [NSURL fileURLWithPath:g_videoFile];
        _videoAsset = [AVAsset assetWithURL:videoURL];
        vcam_logf(@"Carregando vídeo do caminho: %@", g_videoFile);
        
        if (!_videoAsset) {
            vcam_log(@"Falha ao criar asset para o vídeo");
            return NO;
        }
        
        NSError *error = nil;
        _reader = [AVAssetReader assetReaderWithAsset:_videoAsset error:&error];
        if (error) {
            vcam_logf(@"Erro ao criar asset reader: %@", error);
            return NO;
        }
        
        AVAssetTrack *videoTrack = [[_videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!videoTrack) {
            vcam_log(@"Não foi possível encontrar uma trilha de vídeo");
            return NO;
        }
        
        vcam_logf(@"Informações da trilha de vídeo: %@", videoTrack);
        
        // Configuramos outputs para diferentes formatos de pixel
        NSDictionary *outputSettings32BGRA = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
        _videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings32BGRA];
        
        NSDictionary *outputSettingsVideoRange = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        _videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettingsVideoRange];
        
        NSDictionary *outputSettingsFullRange = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        _videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettingsFullRange];
        
        if (!_videoTrackout_32BGRA || !_videoTrackout_420YpCbCr8BiPlanarVideoRange || !_videoTrackout_420YpCbCr8BiPlanarFullRange) {
            vcam_log(@"Falha ao criar outputs para os diferentes formatos");
            return NO;
        }
        
        [_reader addOutput:_videoTrackout_32BGRA];
        [_reader addOutput:_videoTrackout_420YpCbCr8BiPlanarVideoRange];
        [_reader addOutput:_videoTrackout_420YpCbCr8BiPlanarFullRange];
        
        if (![_reader startReading]) {
            vcam_logf(@"Falha ao iniciar leitura: %@", _reader.error);
            return NO;
        }
        
        vcam_log(@"Leitura do vídeo iniciada com sucesso");
        return YES;
        
    } @catch(NSException *except) {
        vcam_logf(@"ERRO ao inicializar leitura do vídeo: %@", except);
        return NO;
    }
}

// Verifica se o leitor de vídeo está no fim e reinicia se necessário
- (void)checkAndRestartReaderIfNeeded {
    if (_reader && _reader.status == AVAssetReaderStatusCompleted) {
        vcam_log(@"Vídeo chegou ao fim, reiniciando leitor");
        [self releaseResources];
        [self setupVideoReader];
    }
}

// Método para obter o frame atual de vídeo
- (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer forceReNew:(BOOL)forceReNew {
    __block CMSampleBufferRef result = nil;
    
    dispatch_sync(_processingQueue, ^{
        vcam_log(@"GetFrame::getCurrentFrame - Início da função");
        
        // Informações do buffer original
        CMFormatDescriptionRef formatDescription = nil;
        CMMediaType mediaType = -1;
        FourCharCode subMediaType = -1;
        
        // Se temos um buffer de entrada, extraímos suas informações
        if (originSampleBuffer != nil) {
            formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
            if (formatDescription) {
                mediaType = CMFormatDescriptionGetMediaType(formatDescription);
                subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
                
                vcam_logf(@"Buffer original - MediaType: %d, SubMediaType: %d", (int)mediaType, (int)subMediaType);
                
                // Se não for vídeo, retornamos o buffer original sem alterações
                if (mediaType != kCMMediaType_Video) {
                    vcam_log(@"Não é vídeo, retornando buffer original sem alterações");
                    result = originSampleBuffer;
                    return;
                }
            }
        } else {
            vcam_log(@"Nenhum buffer de entrada fornecido");
        }
        
        // Verificamos se existe um arquivo de vídeo para substituição
        if (![g_fileManager fileExistsAtPath:g_videoFile]) {
            vcam_log(@"Arquivo de vídeo para substituição não encontrado, retornando NULL");
            result = nil;
            return;
        }
        
        // Se já temos um buffer válido e não precisamos forçar renovação, retornamos o mesmo
        if (_sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(_sampleBuffer) && !forceReNew) {
            vcam_log(@"Reutilizando buffer existente");
            result = _sampleBuffer;
            return;
        }
        
        // Se precisamos recarregar o vídeo, inicializamos os componentes de leitura
        if (g_bufferReload || !_reader) {
            g_bufferReload = NO;
            vcam_log(@"Iniciando carregamento do novo vídeo");
            
            [self releaseResources];
            if (![self setupVideoReader]) {
                vcam_log(@"Falha ao configurar leitor de vídeo");
                result = nil;
                return;
            }
        }
        
        // Verificar se o leitor chegou ao final e reiniciar se necessário
        [self checkAndRestartReaderIfNeeded];
        
        // Obtém um novo frame de cada formato
        vcam_log(@"Copiando próximo frame de cada formato");
        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [_videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];
        
        CMSampleBufferRef newsampleBuffer = nil;
        
        // Escolhe o buffer adequado com base no formato do buffer original
        switch(subMediaType) {
            case kCVPixelFormatType_32BGRA:
                vcam_log(@"Usando formato: kCVPixelFormatType_32BGRA");
                if (videoTrackout_32BGRA_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
                }
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                vcam_log(@"Usando formato: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange");
                if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer);
                }
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                vcam_log(@"Usando formato: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange");
                if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                }
                break;
            default:
                //vcam_logf(@"Formato não reconhecido (%d), usando 32BGRA como padrão", (int)subMediaType);
                vcam_logf(@"Formato não reconhecido (%d), usando 420F como padrão", (int)subMediaType);
                if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                }
        }
        
        // Libera os buffers temporários
        if (videoTrackout_32BGRA_Buffer != nil) {
            CFRelease(videoTrackout_32BGRA_Buffer);
            vcam_log(@"Buffer 32BGRA liberado");
        }
        if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer != nil) {
            CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
            vcam_log(@"Buffer 420YpCbCr8BiPlanarVideoRange liberado");
        }
        if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer != nil) {
            CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);
            vcam_log(@"Buffer 420YpCbCr8BiPlanarFullRange liberado");
        }
        
        // Se não conseguimos criar um novo buffer, marca para recarregar na próxima vez
        if (newsampleBuffer == nil) {
            g_bufferReload = YES;
            vcam_log(@"Falha ao criar novo sample buffer, marcando para recarregar");
            result = nil;
            return;
        }
        
        // Libera o buffer antigo se existir
        if (_sampleBuffer != nil) {
            CFRelease(_sampleBuffer);
            _sampleBuffer = nil;
            vcam_log(@"Buffer antigo liberado");
        }
        
        // Se temos um buffer original, precisamos copiar propriedades dele
        if (originSampleBuffer != nil) {
            vcam_log(@"Processando buffer com base no original");
            
            CMSampleBufferRef copyBuffer = nil;
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);
            
            if (pixelBuffer) {
                vcam_logf(@"Dimensões do pixel buffer: %ldx%ld",
                           CVPixelBufferGetWidth(pixelBuffer),
                           CVPixelBufferGetHeight(pixelBuffer));
                
                // Obtém informações de tempo do buffer original
                CMSampleTimingInfo sampleTime = {
                    .duration = CMSampleBufferGetDuration(originSampleBuffer),
                    .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                    .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
                };
                
                vcam_logf(@"Timing do buffer - Duration: %lld, PTS: %lld, DTS: %lld",
                          sampleTime.duration.value,
                          sampleTime.presentationTimeStamp.value,
                          sampleTime.decodeTimeStamp.value);
                
                // Cria descrição de formato de vídeo para o novo buffer
                CMVideoFormatDescriptionRef videoInfo = nil;
                OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                
                if (status == noErr && videoInfo != nil) {
                    // Cria um novo buffer baseado no pixelBuffer mas com as informações de tempo do original
                    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &sampleTime, &copyBuffer);
                    
                    if (status == noErr && copyBuffer != nil) {
                        vcam_log(@"Buffer copiado com sucesso");
                        _sampleBuffer = copyBuffer;
                    } else {
                        vcam_logf(@"FALHA ao criar buffer copiado: status %d", (int)status);
                    }
                    
                    CFRelease(videoInfo);
                } else {
                    vcam_logf(@"FALHA ao criar descrição de formato: status %d", (int)status);
                }
            }
            
            CFRelease(newsampleBuffer);
        } else {
            // Se não temos buffer original, usamos o novo diretamente
            vcam_log(@"Usando novo buffer diretamente (sem buffer original)");
            _sampleBuffer = newsampleBuffer;
        }
        
        // Verifica se o buffer final é válido
        if (_sampleBuffer != nil && CMSampleBufferIsValid(_sampleBuffer)) {
            vcam_log(@"GetFrame::getCurrentFrame - Retornando buffer válido");
            result = _sampleBuffer;
        } else {
            vcam_log(@"GetFrame::getCurrentFrame - Retornando NULL (buffer inválido)");
            result = nil;
        }
    });
    
    return result;
}

// Método para obter a janela principal da aplicação
+(UIWindow*)getKeyWindow{
    vcam_log(@"GetFrame::getKeyWindow - Buscando janela principal");
    
    // Necessário usar [GetFrame getKeyWindow].rootViewController
    UIWindow *keyWindow = nil;
    if (keyWindow == nil) {
        NSArray *windows = UIApplication.sharedApplication.windows;
        for(UIWindow *window in windows){
            if(window.isKeyWindow) {
                keyWindow = window;
                vcam_log(@"Janela principal encontrada");
                break;
            }
        }
    }
    return keyWindow;
}
@end


// Elementos de UI para o tweak
static CALayer *g_maskLayer = nil;

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    vcam_logf(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer: %@", layer);
    %orig;

    // Configura display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        
        // Ajusta a taxa de frames baseado no dispositivo
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 30; // 30 FPS para economia de bateria
        } else {
            displayLink.frameInterval = 2; // Aproximadamente 30 FPS em dispositivos mais antigos
        }
        
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        vcam_log(@"DisplayLink criado para atualização contínua");
    }

    // Adiciona camada de preview se ainda não existe
    if (![[self sublayers] containsObject:g_previewLayer]) {
        vcam_log(@"Configurando camadas de preview");
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0; // Começa invisível
        
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        g_previewLayer.opacity = 0; // Começa invisível

        // Inicializa tamanho das camadas na thread principal
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            vcam_logf(@"Tamanho das camadas inicializado: %@",
                     NSStringFromCGRect([UIApplication sharedApplication].keyWindow.bounds));
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender{
    // Cache de verificação de existência do arquivo para evitar múltiplas verificações
    static NSTimeInterval lastFileCheckTime = 0;
    static BOOL fileExists = NO;
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica a existência do arquivo a cada segundo
    if (currentTime - lastFileCheckTime > 1.0) {
        fileExists = [g_fileManager fileExistsAtPath:g_videoFile];
        lastFileCheckTime = currentTime;
    }
    
    // Controla a visibilidade das camadas baseado na existência do arquivo de vídeo
    if (fileExists) {
        // Animação suave para mostrar as camadas, se não estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity < 1.0) {
            g_maskLayer.opacity = MIN(g_maskLayer.opacity + 0.1, 1.0);
        }
        if (g_previewLayer != nil) {
            if (g_previewLayer.opacity < 1.0) {
                g_previewLayer.opacity = MIN(g_previewLayer.opacity + 0.1, 1.0);
            }
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
    } else {
        // Animação suave para esconder as camadas, se estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = MAX(g_maskLayer.opacity - 0.1, 0.0);
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = MAX(g_previewLayer.opacity - 0.1, 0.0);
        }
        return; // Evita processamento adicional se não houver arquivo
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        }
        
        // Aplica rotação apenas se a orientação mudou
        if (g_photoOrientation != g_lastOrientation) {
            g_lastOrientation = g_photoOrientation;
            
            switch(g_photoOrientation) {
                case AVCaptureVideoOrientationPortrait:
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                default:
                    g_previewLayer.transform = self.transform;
            }
        }

        // Controle para evitar conflito com VideoDataOutput
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = currentTime * 1000;
        
        // Atualiza o preview apenas se não houver atualização recente do VideoDataOutput
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            // Controle de taxa de frames (30 FPS)
            if (nowTime - refreshTime > 1000 / 30 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                
                // Obtém o próximo frame
                CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:nil forceReNew:NO];
                if (newBuffer != nil) {
                    // Limpa quaisquer frames na fila
                    [g_previewLayer flush];
                    
                    // Cria uma cópia e adiciona à camada de preview
                    static CMSampleBufferRef copyBuffer = nil;
                    if (copyBuffer != nil) {
                        CFRelease(copyBuffer);
                        copyBuffer = nil;
                    }
                    
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer != nil) {
                        [g_previewLayer enqueueSampleBuffer:copyBuffer];
                    }
                }
            }
        }
    }
}
%end


// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    vcam_log(@"AVCaptureSession::startRunning - Câmera iniciando");
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
    vcam_logf(@"AVCaptureSession iniciada com preset: %@", [self sessionPreset]);
    %orig;
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    vcam_log(@"AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    %orig;
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    vcam_logf(@"AVCaptureSession::addInput - Adicionando dispositivo: %@", [input device]);
    
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
        vcam_logf(@"Posição da câmera definida como: %@", g_cameraPosition);
    }
    %orig;
}

// Método chamado quando um dispositivo de saída é adicionado à sessão
- (void)addOutput:(AVCaptureOutput *)output{
    vcam_logf(@"AVCaptureSession::addOutput - Adicionando output: %@", output);
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    vcam_logf(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Delegate: %@, Queue: %@", sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        vcam_log(@"Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if (![hooked containsObject:className]) {
        vcam_logf(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Verifica as configurações de vídeo
        vcam_logf(@"Configurações de vídeo: %@", [self videoSettings]);
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Atualiza timestamp para controle de conflito com preview
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                
                // Armazena a orientação atual do vídeo
                g_photoOrientation = [connection videoOrientation];
                
                // Verifica se o arquivo de vídeo existe antes de tentar substituir
                if ([g_fileManager fileExistsAtPath:g_videoFile]) {
                    // Obtém um frame do vídeo para substituir o buffer
                    CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:sampleBuffer forceReNew:NO];
                    
                    // Atualiza o preview usando o buffer
                    if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                    }
                    
                    // Chama o método original com o buffer substituído
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer != nil ? newBuffer : sampleBuffer, connection);
                }
                
                // Se não há vídeo para substituir, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Variáveis para controle da interface de usuário
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Hook para os controles de volume
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        vcam_log(@"Sequência volume-up + volume-down detectada, abrindo menu");

        // Verifica se o arquivo de vídeo existe
        BOOL videoActive = [g_fileManager fileExistsAtPath:g_videoFile];
        
        // Cria alerta para mostrar status e opções
        NSString *title = videoActive ? @"iOS-VCAM ✅" : @"iOS-VCAM";
        NSString *message = videoActive ?
            @"A substituição do feed da câmera está ativa." :
            @"A substituição do feed da câmera está desativada.";
        
        UIAlertController *alertController = [UIAlertController
            alertControllerWithTitle:title
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        
        // Opção para desativar substituição (só aparece se estiver ativo)
        if (videoActive) {
            UIAlertAction *disableAction = [UIAlertAction
                actionWithTitle:@"Desativar substituição"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    vcam_log(@"Opção 'Desativar substituição' escolhida");
                    
                    // Força a liberação de recursos antes de tentar remover o arquivo
                    g_bufferReload = YES;
                    g_canReleaseBuffer = YES;
                    
                    // Libera referências ao vídeo
                    [[GetFrame sharedInstance] performSelector:@selector(releaseResources)];
                    
                    // Tenta remover o arquivo com várias abordagens para garantir que funcione
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        vcam_log(@"Tentando remover arquivo de vídeo");
                        
                        // Primeira tentativa - método padrão
                        NSError *error = nil;
                        BOOL success = [g_fileManager removeItemAtPath:g_videoFile error:&error];
                        
                        if (!success) {
                            vcam_logf(@"Primeira tentativa falhou: %@", error);
                            
                            // Segunda tentativa - usando funções POSIX
                            int result = unlink([g_videoFile UTF8String]);
                            if (result != 0) {
                                vcam_logf(@"Segunda tentativa falhou com erro: %d", errno);
                                
                                // Terceira tentativa - criar arquivo vazio para sobrescrever
                                [@"" writeToFile:g_videoFile atomically:YES encoding:NSUTF8StringEncoding error:&error];
                                [g_fileManager removeItemAtPath:g_videoFile error:nil];
                            }
                        }
                        
                        // Verifica se a remoção foi bem-sucedida
                        if (![g_fileManager fileExistsAtPath:g_videoFile]) {
                            vcam_log(@"Arquivo de vídeo removido com sucesso");
                            
                            // Avisa o usuário que o vídeo foi desativado
                            UIAlertController *successAlert = [UIAlertController
                                alertControllerWithTitle:@"Sucesso"
                                message:@"A substituição do feed da câmera foi desativada."
                                preferredStyle:UIAlertControllerStyleAlert];
                            
                            UIAlertAction *okAction = [UIAlertAction
                                actionWithTitle:@"OK"
                                style:UIAlertActionStyleDefault
                                handler:nil];
                            
                            [successAlert addAction:okAction];
                            [[GetFrame getKeyWindow].rootViewController presentViewController:successAlert animated:YES completion:nil];
                        } else {
                            vcam_log(@"Falha ao remover arquivo de vídeo");
                            
                            // Informa o usuário sobre a falha
                            UIAlertController *failureAlert = [UIAlertController
                                alertControllerWithTitle:@"Erro"
                                message:@"Não foi possível desativar a substituição do feed da câmera. Tente novamente."
                                preferredStyle:UIAlertControllerStyleAlert];
                            
                            UIAlertAction *okAction = [UIAlertAction
                                actionWithTitle:@"OK"
                                style:UIAlertActionStyleDefault
                                handler:nil];
                            
                            [failureAlert addAction:okAction];
                            [[GetFrame getKeyWindow].rootViewController presentViewController:failureAlert animated:YES completion:nil];
                        }
                    });
                }];
            [alertController addAction:disableAction];
        }
        
        // Opção para informações de status
        UIAlertAction *statusAction = [UIAlertAction
            actionWithTitle:@"Ver status"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                vcam_log(@"Opção 'Ver status' escolhida");
                
                // Coleta informações de status
                NSString *statusInfo = [NSString stringWithFormat:
                    @"Arquivo de vídeo: %@\n"
                    @"Câmera ativa: %@\n"
                    @"Posição da câmera: %@\n"
                    @"Orientação: %d\n"
                    @"Aplicativo atual: %@",
                    [g_fileManager fileExistsAtPath:g_videoFile] ? @"Presente" : @"Ausente",
                    g_cameraRunning ? @"Sim" : @"Não",
                    g_cameraPosition,
                    (int)g_photoOrientation,
                    [NSProcessInfo processInfo].processName
                ];
                
                UIAlertController *statusAlert = [UIAlertController
                    alertControllerWithTitle:@"Status do iOS-VCAM"
                    message:statusInfo
                    preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *okAction = [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil];
                
                [statusAlert addAction:okAction];
                [[GetFrame getKeyWindow].rootViewController presentViewController:statusAlert animated:YES completion:nil];
            }];
        
        // Opção para cancelar
        UIAlertAction *cancelAction = [UIAlertAction
            actionWithTitle:@"Fechar"
            style:UIAlertActionStyleCancel
            handler:nil];
        
        // Adiciona as ações ao alerta
        [alertController addAction:statusAction];
        [alertController addAction:cancelAction];
        
        // Apresenta o alerta
        [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];
    }
    
    // Salva o timestamp atual
    g_volume_down_time = nowtime;
    
    // Chama o método original
    %orig;
}
%end

// Função chamada quando o tweak é carregado
%ctor {
    vcam_log(@"--------------------------------------------------");
    vcam_log(@"VCamTeste - Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        vcam_log(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializa recursos globais
    vcam_log(@"Inicializando recursos globais");
    g_fileManager = [NSFileManager defaultManager];
    
    vcam_logf(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    vcam_logf(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    vcam_log(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor{
    vcam_log(@"VCamTeste - Finalizando tweak");
    
    // Limpa variáveis globais
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    
    vcam_log(@"Tweak finalizado com sucesso");
    vcam_log(@"--------------------------------------------------");
}
