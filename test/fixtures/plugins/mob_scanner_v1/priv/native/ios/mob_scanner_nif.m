/* mob_scanner_nif — iOS QR/barcode scanner tier-1 plugin NIF (Objective-C).
 *
 * Extracted from mob-core ios/mob_nif.m (the "QR / barcode scanner" section,
 * mob_nif.m:2939-3046): MobScannerVC, a full-screen AVCaptureMetadataOutput
 * view controller. Self-contained — core's mob_send2 / mob_root_vc are
 * private statics, so this ships its own (scan_send2 / scan_root_vc).
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc).
 *
 * Delivered message shapes (exact core parity):
 *   not_available -> {scan, not_available}   (mob_nif.m:2957)
 *   cancelled     -> {scan, cancelled}       (mob_nif.m:2991)
 *   result        -> {scan, result, #{type => atom, value => binary}}
 *                    (mob_nif.m:3016-3031 — type as an ATOM, value as a
 *                    binary, delivered as direct Erlang terms; the Android
 *                    side goes through the {:mob_file_result, ...} JSON
 *                    path instead, decoded by core Mob.Screen into the
 *                    same user-facing tuple, lib/mob/screen.ex:382-384)
 *
 * PARITY: core's nif_scanner_scan is arity 1 (mob_nif.m:6014) but ignores
 * the formats JSON argument — the metadataObjectTypes list is hardcoded
 * (mob_nif.m:2966-2971). Preserved exactly. The :camera permission flow is
 * NOT here — it is owned by the mob_camera plugin.
 */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>

// Self-contained {atom, atom} send (core's mob_send2 is a private static).
static void scan_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
    enif_send(NULL, (ErlNifPid *)pid, e, msg);
    enif_free_env(e);
}

// Root view controller for presenting the scanner (core's mob_root_vc is a
// private static).
static UIViewController *scan_root_vc(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
            if (w.rootViewController)
                return w.rootViewController;
        }
    }
    return nil;
}

// ── QR / barcode scanner ──────────────────────────────────────────────────

@interface MobScannerVC : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic) ErlNifPid pid;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@end

static MobScannerVC *g_scanner_vc = nil;

@implementation MobScannerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    NSError *err = nil;
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *inp = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!inp) {
        scan_send2(&_pid, "scan", "not_available");
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.session = [[AVCaptureSession alloc] init];
    [self.session addInput:inp];
    AVCaptureMetadataOutput *out = [[AVCaptureMetadataOutput alloc] init];
    [self.session addOutput:out];
    [out setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    out.metadataObjectTypes = @[
        AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code,
        AVMetadataObjectTypeCode128Code, AVMetadataObjectTypeCode39Code,
        AVMetadataObjectTypeAztecCode, AVMetadataObjectTypePDF417Code,
        AVMetadataObjectTypeDataMatrixCode
    ];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preview.frame = self.view.bounds;
    [self.view.layer addSublayer:self.preview];
    // Cancel button
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"Cancel" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.frame = CGRectMake(16, 60, 80, 44);
    [btn addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    [self.session startRunning];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.preview.frame = self.view.bounds;
}
- (void)cancel {
    [self.session stopRunning];
    scan_send2(&_pid, "scan", "cancelled");
    [self dismissViewControllerAnimated:YES completion:nil];
    g_scanner_vc = nil;
}
- (void)captureOutput:(AVCaptureOutput *)out
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metas
              fromConnection:(AVCaptureConnection *)conn {
    AVMetadataMachineReadableCodeObject *code = metas.firstObject;
    if (!code || !code.stringValue)
        return;
    [self.session stopRunning];
    NSString *val = code.stringValue;
    NSString *typ = @"qr";
    if ([code.type isEqualToString:AVMetadataObjectTypeEAN13Code])
        typ = @"ean13";
    else if ([code.type isEqualToString:AVMetadataObjectTypeEAN8Code])
        typ = @"ean8";
    else if ([code.type isEqualToString:AVMetadataObjectTypeCode128Code])
        typ = @"code128";
    else if ([code.type isEqualToString:AVMetadataObjectTypeCode39Code])
        typ = @"code39";
    ErlNifPid p = self.pid;
    g_scanner_vc = nil;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                               ErlNifEnv *e = enif_alloc_env();
                               const char *cval = val.UTF8String;
                               const char *ctyp = typ.UTF8String;
                               ErlNifBinary vb;
                               enif_alloc_binary(strlen(cval), &vb);
                               memcpy(vb.data, cval, strlen(cval));
                               ERL_NIF_TERM keys[2] = {enif_make_atom(e, "type"),
                                                       enif_make_atom(e, "value")};
                               ERL_NIF_TERM vals[2] = {enif_make_atom(e, ctyp),
                                                       enif_make_binary(e, &vb)};
                               ERL_NIF_TERM map;
                               enif_make_map_from_arrays(e, keys, vals, 2, &map);
                               ERL_NIF_TERM msg = enif_make_tuple3(
                                   e, enif_make_atom(e, "scan"), enif_make_atom(e, "result"), map);
                               enif_send(NULL, &p, e, msg);
                               enif_free_env(e);
                             }];
}
@end

static ERL_NIF_TERM nif_scanner_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
      g_scanner_vc = [[MobScannerVC alloc] init];
      g_scanner_vc.pid = pid;
      g_scanner_vc.modalPresentationStyle = UIModalPresentationFullScreen;
      [scan_root_vc() presentViewController:g_scanner_vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
// No load callback needed (unlike mob_camera, which registers a permission
// handler at load) — the :camera permission flow is owned by mob_camera.

static ErlNifFunc nif_funcs[] = {
    {"scanner_scan", 1, nif_scanner_scan, 0},
};

ERL_NIF_INIT(mob_scanner_nif, nif_funcs, NULL, NULL, NULL, NULL)
