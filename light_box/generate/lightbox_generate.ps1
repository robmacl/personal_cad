# Generates the light box v2 printed parts in a running SolidWorks session.
#
#   powershell -ExecutionPolicy Bypass -File lightbox_generate.ps1 [-What gauge|blockA|blockB|bracketA|bracketB|footA|footB|spacer|mock] [-ImgDir <dir>]
#   powershell -ExecutionPolicy Bypass -File lightbox_generate.ps1 -What stl -StlTag <tag> [-StlParts a,b,...]
#
# The second form writes fine STL print files to ../stl/lb_<part>_<tag>.STL.
# Every dimension comes from lightbox_params.json (millimetres). Edit it and run again: parts are
# stripped and rebuilt in place. Sketches carry no dimensions; the JSON and this script are the design.
# See ../light_box_notes.txt. Helpers copied from mindfulnest-hardware/cad/Squeeze/generate.
#
# Frame parts are modelled in the corner-local frame described in the code (not print orientation),
# so the exported meshes can be checked against the mock of the light. One part per run.
param([string]$What = "gauge", [string]$ImgDir = "", [string]$StlTag = "print", [string]$StlParts = "corner_block_A,corner_block_B,bracket_A,bracket_B")

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Split-Path -Parent $here
$redist = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist"
$refs = @("$redist\SolidWorks.Interop.sldworks.dll", "$redist\SolidWorks.Interop.swconst.dll")

$code = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;

public static class Gen {
  static SldWorks sw; static ModelDoc2 doc; static StringBuilder log = new StringBuilder();
  static Dictionary<string, double> P; static List<string> PKeys;
  static Dictionary<string, string> planes = new Dictionary<string, string>();
  const double MM = 0.001;
  static double p(string k) { if (!P.ContainsKey(k)) throw new Exception("missing parameter " + k); return P[k]; }


  // ---------------------------------------------------------------- sketch helpers (model mm in)
  static double[] S(double[] m) {
    Sketch sk = (Sketch)doc.SketchManager.ActiveSketch;
    MathUtility mu = (MathUtility)sw.GetMathUtility();
    MathPoint q = (MathPoint)mu.CreatePoint(new double[] { m[0] * MM, m[1] * MM, m[2] * MM });
    q = (MathPoint)q.MultiplyTransform(sk.ModelToSketchTransform);
    return (double[])q.ArrayData;
  }
  static double[] V(double x, double y, double z) { return new double[] { x, y, z }; }
  static void Open(string plane) {
    doc.ClearSelection2(true);
    if (!doc.Extension.SelectByID2(plane, "PLANE", 0, 0, 0, false, 0, null, 0)) log.AppendLine("  !! could not select plane " + plane);
    doc.SketchManager.InsertSketch(true);
    doc.SketchManager.AddToDB = true;
  }
  static Feature Close(string name) {
    doc.SketchManager.AddToDB = false;
    doc.SketchManager.InsertSketch(true);
    Feature f = (Feature)doc.FeatureByPositionReverse(0);
    f.Name = name;
    return f;
  }
  static SketchSegment Ln(double[] a, double[] b) {
    double d = Math.Sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
    if (d < 1e-6) return null;
    double[] s = S(a), e = S(b);
    return (SketchSegment)doc.SketchManager.CreateLine(s[0], s[1], s[2], e[0], e[1], e[2]);
  }
  static int Turn(double[] s, double[] m, double[] e) { return ((m[0] - s[0]) * (e[1] - m[1]) - (m[1] - s[1]) * (e[0] - m[0])) > 0 ? 1 : -1; }
  static void EllArcM(double[] c, double[] maj, double[] min, double[] s, double[] m, double[] e) {
    double[] C = S(c), A = S(maj), B = S(min), a = S(s), M = S(m), b = S(e);
    object o = doc.SketchManager.CreateEllipticalArc(C[0], C[1], C[2], A[0], A[1], A[2], B[0], B[1], B[2], a[0], a[1], a[2], b[0], b[1], b[2], (short)Turn(a, M, b));
    if (o == null) log.AppendLine("  !! elliptical arc failed");
  }
  static void CircArcM(double[] c, double[] s, double[] m, double[] e) {
    double[] C = S(c), a = S(s), M = S(m), b = S(e);
    object o = doc.SketchManager.CreateArc(C[0], C[1], C[2], a[0], a[1], a[2], b[0], b[1], b[2], (short)Turn(a, M, b));
    if (o == null) log.AppendLine("  !! arc failed");
  }
  static void Circle(double[] c, double dia) {
    double[] C = S(c);
    if (doc.SketchManager.CreateCircleByRadius(C[0], C[1], C[2], dia / 2 * MM) == null) log.AppendLine("  !! circle failed");
  }
  static void Name(Feature f, string n) { if (f != null) f.Name = n; else log.AppendLine("  !! feature failed: " + n); }

  // ---------------------------------------------------------------- features
  static Feature ExtrudeMid(Feature sketch, double depth, bool cut) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    if (cut) return (Feature)doc.FeatureManager.FeatureCut4(true, false, false, (int)swEndConditions_e.swEndCondMidPlane, 0, depth * MM, 0,
      false, false, false, false, 0, 0, false, false, false, false, false, true, true, true, true, false, (int)swStartConditions_e.swStartSketchPlane, 0, false, false);
    return (Feature)doc.FeatureManager.FeatureExtrusion3(true, false, false, (int)swEndConditions_e.swEndCondMidPlane, 0, depth * MM, 0,
      false, false, false, false, 0, 0, false, false, false, false, true, true, true, (int)swStartConditions_e.swStartSketchPlane, 0, false);
  }
  static Feature CutThrough(Feature sketch) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    return (Feature)doc.FeatureManager.FeatureCut4(false, false, false, (int)swEndConditions_e.swEndCondThroughAll, (int)swEndConditions_e.swEndCondThroughAll, 0.01, 0.01,
      false, false, false, false, 0, 0, false, false, false, false, false, true, true, true, true, false, (int)swStartConditions_e.swStartSketchPlane, 0, false, false);
  }
  static Feature Revolve(Feature sketch, SketchSegment axis, bool half, bool cut) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    SelectData sd = (SelectData)((SelectionMgr)doc.SelectionManager).CreateSelectData();
    sd.Mark = 16;
    axis.Select4(true, sd);
    return (Feature)doc.FeatureManager.FeatureRevolve2(true, true, false, cut, false, false,
      half ? (int)swEndConditions_e.swEndCondMidPlane : (int)swEndConditions_e.swEndCondBlind, 0, half ? Math.PI : 2 * Math.PI, 0,
      false, false, 0, 0, 0, 0, 0, true, true, true);
  }

  // offset reference planes, cached. idx 0: parallel to Right (x = v); 1: parallel to Top (y = v); 2: parallel to Front (z = v)
  static string PlaneAt(int idx, double v) {
    string[] bases = { "Right Plane", "Top Plane", "Front Plane" };
    if (Math.Abs(v) < 1e-6) return bases[idx];
    string key = "P" + "XYZ"[idx] + " " + v.ToString("F3");
    if (planes.ContainsKey(key)) return planes[key];
    for (int attempt = 0; attempt < 2; attempt++) {
      doc.ClearSelection2(true);
      doc.Extension.SelectByID2(bases[idx], "PLANE", 0, 0, 0, false, 0, null, 0);
      int opt = (int)swRefPlaneReferenceConstraints_e.swRefPlaneReferenceConstraint_Distance;
      bool flip = (v < 0) ^ (attempt == 1);
      if (flip) opt |= (int)swRefPlaneReferenceConstraints_e.swRefPlaneReferenceConstraint_OptionFlip;
      Feature f = (Feature)doc.FeatureManager.InsertRefPlane(opt, Math.Abs(v) * MM, 0, 0, 0, 0);
      if (f == null) { log.AppendLine("  !! plane failed " + key); continue; }
      RefPlane rp = (RefPlane)f.GetSpecificFeature2();
      double[] t = (double[])rp.Transform.ArrayData;
      double pos = t[9 + idx] / MM;
      if (Math.Abs(pos - v) < 1e-4) { f.Name = key; planes[key] = key; doc.ClearSelection2(true); return key; }
      doc.ClearSelection2(true); f.Select2(false, 0); doc.Extension.DeleteSelection2(0);
    }
    throw new Exception("could not place plane " + key);
  }

  // vertical cylinders: each entry {x, y, dia}; from z1 to z2
  static Feature Cyls(double[][] xyd, double z1, double z2, bool cut, string name) {
    double zm = (z1 + z2) / 2;
    Open(PlaneAt(2, zm));
    foreach (double[] c in xyd) Circle(V(c[0], c[1], zm), c[2]);
    Feature f = ExtrudeMid(Close(name + " sketch"), z2 - z1, cut);
    Name(f, name);
    return f;
  }
  // vertical prism from a closed polygon {x, y}; from z1 to z2
  static Feature Prism(double[][] xy, double z1, double z2, bool cut, string name) {
    double zm = (z1 + z2) / 2;
    Open(PlaneAt(2, zm));
    for (int i = 0; i < xy.Length; i++) { double[] a = xy[i], b = xy[(i + 1) % xy.Length]; Ln(V(a[0], a[1], zm), V(b[0], b[1], zm)); }
    Feature f = ExtrudeMid(Close(name + " sketch"), z2 - z1, cut);
    Name(f, name);
    return f;
  }

  // ---------------------------------------------------------------- document handling
  static bool OpenOrNew(string path) {
    planes.Clear();
    int e = 0, w = 0;
    if (System.IO.File.Exists(path)) {
      doc = (ModelDoc2)sw.OpenDoc6(path, (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
      if (doc == null) { log.AppendLine("!! could not open " + path + " err " + e); return false; }
      doc = (ModelDoc2)sw.ActivateDoc3(doc.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref e);
      List<Feature> kill = new List<Feature>();
      bool after = false;
      Feature f = (Feature)doc.FirstFeature();
      while (f != null) { if (after) kill.Add(f); if (f.GetTypeName2() == "OriginProfileFeature") after = true; f = (Feature)f.GetNextFeature(); }
      if (kill.Count > 0) {
        doc.ClearSelection2(true);
        foreach (Feature k in kill) k.Select2(true, 0);
        doc.Extension.DeleteSelection2((int)swDeleteSelectionOptions_e.swDelete_Absorbed | (int)swDeleteSelectionOptions_e.swDelete_Children);
      }
      object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
      if (bodies != null && bodies.Length > 0) { log.AppendLine("!! could not clear " + path); return false; }
    } else {
      string tpl = sw.GetUserPreferenceStringValue((int)swUserPreferenceStringValue_e.swDefaultTemplatePart);
      doc = (ModelDoc2)sw.NewDocument(tpl, 0, 0, 0);
      if (doc == null) { log.AppendLine("!! NewDocument failed"); return false; }
    }
    return true;
  }
  static void Finish(string path, string tag, double r, double g, double b, string imgDir, string view, int viewId) {
    doc.ClearSelection2(true);
    EquationMgr eq = (EquationMgr)doc.GetEquationMgr();
    foreach (string k in PKeys) eq.Add2(-1, "\"" + k + "\" = " + P[k].ToString("0.####") + "mm", false);
    // hide the construction planes and every sketch
    Feature pf = (Feature)doc.FirstFeature();
    while (pf != null) {
      if (pf.GetTypeName2() == "RefPlane" && planes.ContainsKey(pf.Name)) { doc.ClearSelection2(true); pf.Select2(false, 0); doc.BlankRefGeom(); }
      if (pf.GetTypeName2() == "ProfileFeature") { doc.ClearSelection2(true); pf.Select2(false, 0); doc.BlankSketch(); }
      Feature sf = (Feature)pf.GetFirstSubFeature();
      while (sf != null) { if (sf.GetTypeName2() == "ProfileFeature") { doc.ClearSelection2(true); sf.Select2(false, 0); doc.BlankSketch(); } sf = (Feature)sf.GetNextSubFeature(); }
      pf = (Feature)pf.GetNextFeature();
    }
    doc.ClearSelection2(true);
    doc.ForceRebuild3(false);
    doc.MaterialPropertyValues = new double[] { r, g, b, 1.0, 1.0, 0.2, 0.3, 0.0, 0.0 };
    // report
    object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
    if (bodies == null) { log.AppendLine(tag + ": !! no body"); return; }
    double[] lo = { 1e9, 1e9, 1e9 }, hi = { -1e9, -1e9, -1e9 };
    foreach (object bo in bodies) { double[] bb = (double[])((Body2)bo).GetBodyBox(); for (int i = 0; i < 3; i++) { lo[i] = Math.Min(lo[i], bb[i]); hi[i] = Math.Max(hi[i], bb[i + 3]); } }
    MassProperty mp = (MassProperty)doc.Extension.CreateMassProperty();
    log.AppendLine(String.Format("{0}: bodies {1}  x {2:F1}..{5:F1}  y {3:F1}..{6:F1}  z {4:F1}..{7:F1}  volume {8:F1} cm3", tag, bodies.Length, lo[0] * 1000, lo[1] * 1000, lo[2] * 1000, hi[0] * 1000, hi[1] * 1000, hi[2] * 1000, mp.Volume * 1e6));
    int bad = 0;
    Feature f = (Feature)doc.FirstFeature();
    while (f != null) { bool warn; int ec = f.GetErrorCode2(out warn); if (ec != 0) { bad++; log.AppendLine("  !! " + (warn ? "warning" : "error") + " " + ec + " in feature " + f.Name); } f = (Feature)f.GetNextFeature(); }
    int e = 0, w = 0;
    bool ok = System.IO.File.Exists(path) && String.Equals(doc.GetPathName(), path, StringComparison.OrdinalIgnoreCase)
      ? doc.Save3((int)swSaveAsOptions_e.swSaveAsOptions_Silent, ref e, ref w)
      : doc.Extension.SaveAs(path, 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent, null, ref e, ref w);
    log.AppendLine(tag + ": saved " + ok + (e != 0 ? " err " + e : "") + (bad == 0 ? ", no feature errors" : ""));
    if (imgDir != "") {
      doc.ShowNamedView2(view, viewId); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
      doc.Extension.SaveAs(imgDir + "\\" + tag + ".jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      bool old = sw.GetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive);
      sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, true);
      doc.Extension.SaveAs(imgDir + "\\" + tag + ".STL", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, old);
    }
  }

  // ================================================================ light box v2 parts
  // Corner-local frame (mm): x = 0 on the side plane of the light, +x outward; y = 0 on the end of the
  // housing, +y outward past the end; z = 0 on the front edge of the lamp, +z toward the viewer.
  // Hand "A" is built as written; hand "B" is its mirror in x (sgn = -1).
  static double sgn = 1;
  static string SEP = System.IO.Path.DirectorySeparatorChar.ToString();
  static double[][] Rect(double x1, double y1, double x2, double y2) { return new double[][] { new double[] { x1, y1 }, new double[] { x2, y1 }, new double[] { x2, y2 }, new double[] { x1, y2 } }; }
  static double[][] MirXY(double[][] a) { double[][] r = new double[a.Length][]; for (int i = 0; i < a.Length; i++) r[i] = new double[] { sgn * a[i][0], a[i][1] }; return r; }
  static Feature PZ(double[][] xy, double z1, double z2, bool cut, string name) { return Prism(MirXY(xy), z1, z2, cut, name); }
  // prism along y from a closed polygon {x, z}
  static Feature PY(double[][] xz, double y1, double y2, bool cut, string name) {
    double ym = (y1 + y2) / 2;
    Open(PlaneAt(1, ym));
    for (int i = 0; i < xz.Length; i++) { double[] a = xz[i], b = xz[(i + 1) % xz.Length]; Ln(V(sgn * a[0], ym, a[1]), V(sgn * b[0], ym, b[1])); }
    Feature f = ExtrudeMid(Close(name + " sketch"), y2 - y1, cut);
    Name(f, name);
    return f;
  }
  // prism along x from a closed polygon {y, z}
  static Feature PX(double[][] yz, double x1, double x2, bool cut, string name) {
    double xm = sgn * (x1 + x2) / 2;
    Open(PlaneAt(0, xm));
    for (int i = 0; i < yz.Length; i++) { double[] a = yz[i], b = yz[(i + 1) % yz.Length]; Ln(V(xm, a[0], a[1]), V(xm, b[0], b[1])); }
    Feature f = ExtrudeMid(Close(name + " sketch"), Math.Abs(x2 - x1), cut);
    Name(f, name);
    return f;
  }
  // cylinders along x: each entry {y, z, dia}
  static Feature CX(double[][] yzd, double x1, double x2, bool cut, string name) {
    double xm = sgn * (x1 + x2) / 2;
    Open(PlaneAt(0, xm));
    foreach (double[] c in yzd) Circle(V(xm, c[0], c[1]), c[2]);
    Feature f = ExtrudeMid(Close(name + " sketch"), Math.Abs(x2 - x1), cut);
    Name(f, name);
    return f;
  }
  // round cut about an axis lying in the plane y = yc: from (ax, az) along unit (nx, nz) for len, radius r
  static Feature RevCutY(double yc, double ax, double az, double nx, double nz, double len, double r, string name) {
    double dx = -nz, dz = nx;
    Open(PlaneAt(1, yc));
    double[] a0 = V(sgn * ax, yc, az), a1 = V(sgn * (ax + len * nx), yc, az + len * nz);
    double[] b1 = V(sgn * (ax + len * nx + r * dx), yc, az + len * nz + r * dz), b0 = V(sgn * (ax + r * dx), yc, az + r * dz);
    SketchSegment axis = Ln(a0, a1); Ln(a1, b1); Ln(b1, b0); Ln(b0, a0);
    Feature f = Revolve(Close(name + " sketch"), axis, false, true);
    Name(f, name);
    return f;
  }

  class Lay {
    public double zf, zFront, zRearIn, zRearOut, zb, zSeat, zTop, zScrew;
    public double webInX, webOutX, bumpX, tipX, webInY, webOutY, bumpY, tipY;
    public double xe, ys, yi, slopeAng, dX, dZ, nX, nZ, cX, cZ, jog;
  }
  static Lay L() {
    Lay a = new Lay();
    a.zf = p("gap") + p("diffT");                       // inside of the front leg of the channel = diffuser front
    a.zFront = a.zf + p("chanFloor");
    a.zRearIn = a.zf - p("chanSlotW");
    a.zRearOut = a.zRearIn - p("chanFloor");
    a.zb = a.zRearIn + p("tongueClrZ");                 // underside of block and tongues
    a.zSeat = p("gap") - p("seatClr");                  // top of tongues and body: the back of the diffuser rests here
    a.zTop = a.zFront + p("proud");
    a.zScrew = (a.zb + a.zSeat) / 2;
    a.webInX = (p("diffW") + 2 * p("edgeW") - p("lightW")) / 2;
    a.webOutX = a.webInX + p("chanFloor"); a.bumpX = a.webOutX + p("proud"); a.tipX = a.webInX - p("chanSlotDepth");
    a.webInY = (p("diffL") + 2 * p("edgeL") - p("lightL")) / 2;
    a.webOutY = a.webInY + p("chanFloor"); a.bumpY = a.webOutY + p("proud"); a.tipY = a.webInY - p("chanSlotDepth");
    a.xe = a.webOutX - p("armEnd"); a.ys = a.webOutY - p("armSide");
    a.yi = -p("insFromEnd");
    double rise = p("lightWingDepth") - p("lightSideFlat"), len = p("lightSlopeLen"), run = Math.Sqrt(len * len - rise * rise);
    a.dX = -run / len; a.dZ = -rise / len;              // down the angled face, away from the side-flat bend
    a.nX = -a.dZ; a.nZ = a.dX;                          // out of the angled face
    a.slopeAng = Math.Atan2(rise, run) * 180 / Math.PI;
    a.cX = p("insUpSlope") * a.dX; a.cZ = -p("lightSideFlat") + p("insUpSlope") * a.dZ;
    a.jog = a.webOutX;
    return a;
  }
  static void LayoutReport(Lay a) {
    log.AppendLine(String.Format("  layout: frame outside {0:F1} x {1:F1}; channel z {2:F2}..{3:F2}; diffuser z {4:F2}..{5:F2}",
      p("lightW") + 2 * a.webOutX, p("lightL") + 2 * a.webOutY, a.zRearOut, a.zFront, p("gap"), a.zf));
    log.AppendLine(String.Format("  frame proud of light: side {0:F2}, end {1:F2}; angled face {2:F1} deg; insert at x {3:F1}, y {4:F1}, z {5:F1}",
      a.webOutX, a.webOutY, a.slopeAng, a.cX, a.yi, a.cZ));
    log.AppendLine(String.Format("  CUT LENGTHS: side channels {0:F1} mm ({1:F3} in), end channels {2:F1} mm ({3:F3} in)",
      p("lightL") + 2 * a.webOutY - 2 * p("armSide"), (p("lightL") + 2 * a.webOutY - 2 * p("armSide")) / 25.4,
      p("lightW") + 2 * a.webOutX - 2 * p("armEnd"), (p("lightW") + 2 * a.webOutX - 2 * p("armEnd")) / 25.4));
    double tt = a.zSeat - a.zb;
    log.AppendLine(String.Format("  tongue: {0:F2} thick (slot {1:F2} - diffuser {2:F2} - clearances), {3:F2} deep in the slot, {4:F0} long",
      tt, p("chanSlotW"), p("diffT"), a.webInX - p("tongueClrX") - a.tipX, p("tongueLen")));
    if (tt < 6) log.AppendLine("  !! tongue under 6 mm thick");
    if (a.webOutX < 0.5) log.AppendLine("  !! frame is not proud of the side of the light: bracket joggle under 0.5");
    if (a.zb < 8) log.AppendLine("  !! frame back is under 8 mm from the lamp front");
  }

  // ---------------------------------------------------------------- corner block: joins two channels, seats the diffuser corner
  static void BuildBlock(string path, string imgDir, string tag) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); LayoutReport(a);
    double c = p("cornerCham"), lt = p("tongueLen"), tx = a.webInX - p("tongueClrX"), ty = a.webInY - p("tongueClrX");
    // body and tongues, zb..zSeat
    PZ(new double[][] {
      new double[] { a.bumpX, a.bumpY - c }, new double[] { a.bumpX - c, a.bumpY },
      new double[] { a.xe, a.bumpY }, new double[] { a.xe, ty }, new double[] { a.xe - lt, ty }, new double[] { a.xe - lt, a.tipY },
      new double[] { a.tipX, a.tipY },
      new double[] { a.tipX, a.ys - lt }, new double[] { tx, a.ys - lt }, new double[] { tx, a.ys }, new double[] { a.bumpX, a.ys } },
      a.zb, a.zSeat, false, "body and tongues");
    // rim round the diffuser corner, zb..zTop
    PZ(new double[][] {
      new double[] { a.bumpX, a.bumpY - c }, new double[] { a.bumpX - c, a.bumpY },
      new double[] { a.xe, a.bumpY }, new double[] { a.xe, a.webInY }, new double[] { a.webInX, a.webInY },
      new double[] { a.webInX, a.ys }, new double[] { a.bumpX, a.ys } },
      a.zb, a.zTop, false, "rim");
    // seat for the bracket on the side face
    double bw = p("brkW"), bc = p("brkSeatClr");
    PZ(Rect(a.webOutX, a.yi - bw / 2 - bc, a.bumpX + 1, a.yi + bw / 2 + bc), a.zb - 1, a.zTop + 1, true, "bracket seat");
    double sp = p("brkScrewSpan") / 2;
    CX(new double[][] { new double[] { a.yi - sp, a.zScrew, p("pilotD") }, new double[] { a.yi + sp, a.zScrew, p("pilotD") } },
      a.webOutX - p("pilotDepth"), a.webOutX + 1, true, "screw pilots");
    if (a.webOutX - p("pilotDepth") < a.tipX + 1.5) log.AppendLine("  !! screw pilot breaks through the inside of the block");
    if (a.yi - bw / 2 - bc < a.ys + 3) log.AppendLine("  !! bracket seat runs off the end of the side arm");
    if (a.zScrew - p("pilotD") / 2 - a.zb < 2.5 || a.zSeat - a.zScrew - p("pilotD") / 2 < 2.5) log.AppendLine("  !! under 2.5 mm of plastic around the screw pilots");
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- bracket: frame corner to the M6 insert on the angled face
  static bool footMode = false;
  static void BuildBracket(string path, string imgDir, string tag) {
    if (!OpenOrNew(path)) return;
    Lay a = L();
    double t = p("brkT"), tp = p("padT"), lp = p("padLen"), bw = p("brkW"), sf = p("lightSideFlat");
    double y1 = a.yi - bw / 2, y2 = a.yi + bw / 2;
    double zJ = a.zb - p("jogBelow") - a.jog;
    double sc = p("sideClr");                                       // air between the leg and the side flat: the M6 seats the pad, the leg floats
    if (sc > a.jog - 0.3) log.AppendLine("  !! side clearance leaves no joggle");
    double ex = lp * a.dX, ez = -sf + lp * a.dZ;                      // far end of the pad on the angled face
    double ox = tp * a.nX, oz = -sf + tp * a.nZ;                      // pad outer line passes through here, direction d
        // Inside corner at the bend: a round relief, not a sharp notch (the first print cracked from the sharp corner
    // when the angle was opened by hand). It also keeps the corner off the radius of the sheet-metal bend.
    double rr = p("cornerRelR"), kb = p("cornerRelBack");
    double p0x = sc, p0z = -sf + sc * a.dZ / a.dX;
    double bl = Math.Sqrt(a.dX * a.dX + (1 + a.dZ) * (1 + a.dZ)), bX = a.dX / bl, bZ = (1 + a.dZ) / bl;   // bisector, pointing into the housing
    double crx = p0x - kb * bX, crz = p0z - kb * bZ, db = bZ;                                             // relief centre, inside the plastic; db = d.b = u.b
    double sm = -kb * db + Math.Sqrt(kb * kb * db * db - kb * kb + rr * rr);                              // mouth: this far along each face from the corner
    double aX = p0x + sm * a.dX - crx, aZ = p0z + sm * a.dZ - crz;
    double wX = -bZ, wZ = bX; if (aX * wX + aZ * wZ < 0) { wX = -wX; wZ = -wZ; }   // so the arc runs from the pad face round to the leg face
    double phi = Math.Acos(Math.Max(-1, Math.Min(1, -(aX * bX + aZ * bZ) / rr)));
    List<double[]> prof = new List<double[]>();
    int ns = 14;
    for (int i = 0; i <= ns; i++) { double th = -phi + 2 * phi * i / ns; prof.Add(new double[] { crx + rr * (-Math.Cos(th) * bX - Math.Sin(th) * wX), crz + rr * (-Math.Cos(th) * bZ - Math.Sin(th) * wZ) }); }
    double xo = a.jog + t, so = (xo - ox) / a.dX, zO2 = oz + so * a.dZ;   // leg outer face runs straight down to the pad: no outside joggle, a thicker leg
    prof.Add(new double[] { sc, zJ + sc }); prof.Add(new double[] { a.jog, zJ + a.jog }); prof.Add(new double[] { a.jog, a.zTop });
    prof.Add(new double[] { xo, a.zTop }); prof.Add(new double[] { xo, zO2 });
    prof.Add(new double[] { ex + tp * a.nX, ez + tp * a.nZ }); prof.Add(new double[] { ex, ez });
    { double diag = Math.Sqrt((xo - p0x) * (xo - p0x) + (zO2 - p0z) * (zO2 - p0z));
      log.AppendLine(String.Format("  corner relief: r {0:F1}, mouth {1:F2} along each face, {2:F2} deep; plastic left across the corner about {3:F1}", rr, sm, kb + rr, diag - kb - rr));
      if (diag - kb - rr < 5.5) log.AppendLine("  !! under 5.5 mm of plastic across the bend"); }
    PY(prof.ToArray(),
      y1, y2, false, "leg and pad");
    // relief over the sheet-metal screw head on the side flat near the end of the housing
    PX(Rect(y2 - p("relLen"), -p("relZfar"), y2 + 1, -p("relZnear")), -1, sc + p("relDepth"), true, "screw head relief");
    // the head it clears: centre headFromEnd from the end of the housing, headBack behind the front, dia headD, height headH
    { double m1 = (-p("headFromEnd") - p("headD") / 2) - (y2 - p("relLen")), m2 = p("relZfar") - (p("headBack") + p("headD") / 2), m3 = (p("headBack") - p("headD") / 2) - p("relZnear"), m4 = sc + p("relDepth") - p("headH");
      log.AppendLine(String.Format("  screw head relief margins: along length {0:F1}, toward bend {1:F1}, toward front {2:F1}, depth {3:F1}", m1, m2, m3, m4));
      if (m1 < 1 || m2 < 1.5 || m3 < 1.5 || m4 < 0.5) log.AppendLine("  !! screw head relief is too tight");
      if (p("relZfar") > sf - 2) log.AppendLine("  !! relief runs into the bend"); }
    // M6 slot through the pad, long axis down the slope, and a relief for the flange of the insert
    double hs = p("m6Slot") / 2, r = p("m6Clr") / 2;
    RevCutY(a.yi, a.cX - 1.0 * a.nX, a.cZ - 1.0 * a.nZ, a.nX, a.nZ, 1.0 + p("flangeRelDepth"), p("flangeRelD") / 2, "insert flange relief");
    RevCutY(a.yi, a.cX + hs * a.dX - a.nX, a.cZ + hs * a.dZ - a.nZ, a.nX, a.nZ, tp + 2, r, "M6 slot end 1");
    RevCutY(a.yi, a.cX - hs * a.dX - a.nX, a.cZ - hs * a.dZ - a.nZ, a.nX, a.nZ, tp + 2, r, "M6 slot end 2");
    PY(new double[][] {
      new double[] { a.cX - hs * a.dX - a.nX, a.cZ - hs * a.dZ - a.nZ }, new double[] { a.cX + hs * a.dX - a.nX, a.cZ + hs * a.dZ - a.nZ },
      new double[] { a.cX + hs * a.dX + (tp + 1) * a.nX, a.cZ + hs * a.dZ + (tp + 1) * a.nZ }, new double[] { a.cX - hs * a.dX + (tp + 1) * a.nX, a.cZ - hs * a.dZ + (tp + 1) * a.nZ } },
      a.yi - r, a.yi + r, true, "M6 slot middle");
    double sp = p("brkScrewSpan") / 2;
    CX(new double[][] { new double[] { a.yi - sp, a.zScrew, p("screwClrD") }, new double[] { a.yi + sp, a.zScrew, p("screwClrD") } },
      a.jog - 1, a.jog + t + 1, true, "screw holes");
    log.AppendLine(String.Format("  bracket: leg {0:F1} thick, air span front of lamp to block {1:F1}, pad {2:F1} long on a {3:F1} face, {4:F1} of pad beyond the slot",
      t, a.zb, lp, p("lightSlopeLen"), lp - p("insUpSlope") - hs - r));
    if (lp > p("lightSlopeLen") - 1) log.AppendLine("  !! pad runs past the angled face");
    if (lp - p("insUpSlope") - hs - r < 3) log.AppendLine("  !! under 3 mm of pad beyond the M6 slot");
    if (bw / 2 - sp - p("screwClrD") / 2 < 2.5) log.AppendLine("  !! bracket screws under 2.5 mm from the edge");
    if (p("relDepth") > t - 2.5) log.AppendLine("  !! under 2.5 mm of leg left over the screw head relief");
    // bending check on the leg: a sideways knock F on the frame corner, taken across the air span
    double F = p("knockN"), arm = a.zScrew, I = bw * t * t * t / 12, sig = F * arm * (t / 2) / I, defl = F * arm * arm * arm / (3 * p("petgcfE") * I);
    log.AppendLine(String.Format("  leg bending: {0:F0} N sideways at the frame, arm {1:F1} mm -> {2:F1} MPa, {3:F2} mm deflection (E {4:F0} MPa assumed)", F, arm, sig, defl, p("petgcfE")));
    if (footMode) {
      // FOOT: the bracket for a bottom corner, carried on past the end of the housing (+y) to a sole on the table.
      // Prints sole down. The sole is the lowest thing on the lamp: the corner blocks hang footLift above the table.
      double fc = p("footClr"), yTop = p("footEndClr"), yBot = a.bumpY + p("footLift"), yThin = a.bumpY + p("footBlockClr");
      double zRear = -(p("lightH") + p("footBack")), zStep = a.zRearOut - 0.8, zFwd = a.zTop + p("footFwd");
      double xIn = ex - 0.1, zLegTop = zJ + sc;
      // leg and pad carried down to the sole, standing fc off the housing (end-cap laps, screw heads)
      double fs = (fc + 1.1 - fc * a.nX) / a.dX, fz = -sf + fc * a.nZ + fs * a.dZ;
      PY(new double[][] { new double[] { fc + 1.1, fz }, new double[] { fc + 1.1, zLegTop }, new double[] { xo, zLegTop }, new double[] { xo, zO2 },
        new double[] { ex + tp * a.nX, ez + tp * a.nZ }, new double[] { ex + fc * a.nX, ez + fc * a.nZ } }, y2 - 0.5, yTop + 0.5, false, "foot leg");
      PY(Rect(xIn, zRear, xo, zStep), yTop, yBot, false, "sole under the housing");
      PY(Rect(xIn, zStep - 0.5, xo, zFwd), yThin, yBot, false, "sole under the block");
      // 45 deg gusset under the part of the leg that sits in the block seat, outside the bumper face of the block
      double gx = a.bumpX + 0.4, gz = a.zTop - (yThin - y2);
      PX(new double[][] { new double[] { y2 - 0.5, zLegTop - 0.5 }, new double[] { y2 - 0.5, a.zTop }, new double[] { y2, a.zTop }, new double[] { yThin + 0.5, gz }, new double[] { yThin + 0.5, zLegTop - 0.5 } },
        gx, xo, false, "seat gusset");
      // rib behind the wing of the housing, stiffening the tail of the sole
      double rz = -p("lightWingDepth") - 3, rh = p("footRibH");
      PX(new double[][] { new double[] { yTop + 0.5, rz }, new double[] { yTop - rh, rz }, new double[] { yTop - rh, rz - 4 }, new double[] { yTop, zRear + 2 }, new double[] { yTop + 0.5, zRear + 2 } },
        xIn + 8, xIn + 8 + p("footRibT"), false, "tail rib");
      // diagonal brace: a web outside the side plane of the housing, from the top of the bracket down to the tail of the sole.
      // With bumpers at the two ends of the sole the lamp's weight lands between them; this makes that span a deep beam (creep).
      double zW = zO2 + 1, bx0 = fc + 0.3;
      PX(new double[][] { new double[] { yTop + 0.5, zRear }, new double[] { yTop - p("footBraceEnd"), zRear }, new double[] { y1, zW - 6 }, new double[] { y1, zW }, new double[] { yTop + 0.5, zW } },
        bx0, xo, false, "side brace");
      { double wt = xo - bx0, zh = -p("lightWingDepth"), hh = (yTop - y1) * (zh - zRear) / (zW - 6 - zRear) + (yBot - yTop);   // depth of web + sole where the housing ends
        double span = (a.zTop - 5) - (zRear + 12), la = (a.zTop - 5) - (-p("lightSideFlat")), lb = span - la, W = p("footLoadN");
        double Mb = W * la * lb / span, Iw = wt * hh * hh * hh / 12, sg = Mb * (hh / 2) / Iw, I0 = (xo - xIn) * Math.Pow(yBot - yTop, 3) / 12, sg0 = Mb * ((yBot - yTop) / 2) / I0;
        log.AppendLine(String.Format("  foot span between bumpers {0:F0}; {1:F0} N per foot landing {2:F0} from the front one -> {3:F0} N.mm", span, W, la, Mb));
        log.AppendLine(String.Format("  foot sustained bending: brace + sole {0:F0} deep x {1:F1} -> {2:F2} MPa (sole alone would be {3:F1} MPa)", hh, wt, sg, sg0));
        if (sg > 1.0) log.AppendLine("  !! sustained stress over 1 MPa: creep"); }
      // the side screw-head relief carried through to the end
      PX(Rect(y2 - p("relLen"), -p("relZfar"), yTop - 0.2, -p("relZnear")), -1, sc + p("relDepth"), true, "screw head relief to the end");
      double thin = yBot - yThin, thick = yBot - yTop, wS = xo - xIn, tail = -p("lightWingDepth") - zRear;
      log.AppendLine(String.Format("  foot: sole {0:F1} wide, z {1:F1}..{2:F1} ({3:F0} long); {4:F1} thick under the housing, {5:F1} under the block; table plane y = {6:F2}", wS, zRear, zFwd, zFwd - zRear, thick, thin, yBot));
      log.AppendLine(String.Format("  foot: housing end sits {0:F1} above the sole (end screw heads {1:F1}), block rim {2:F1} above it; table to housing end {3:F1}", yTop, p("endHeadH"), p("footBlockClr"), yBot));
      log.AppendLine(String.Format("  foot: stance front to back {0:F0} mm, {1:F0} behind the housing back, {2:F0} in front of the frame", zFwd - zRear, p("footBack"), p("footFwd")));
      if (yTop < p("endHeadH") + 0.5) log.AppendLine("  !! sole under 0.5 clear of the end screw heads");
      if (thin < 2.5) log.AppendLine("  !! sole under the block is under 2.5 thick");
      if (rz - 4 < zRear + 10) log.AppendLine("  !! no room for the tail rib");
      if (gz < zLegTop) log.AppendLine("  !! gusset geometry inverted");
    }
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- mock of one corner: housing, diffuser, channel stubs (hand A)
  static void BuildMock(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double far = -p("mockExtent"), sf = p("lightSideFlat"), wd = p("lightWingDepth");
    double bx = p("lightSlopeLen") * a.dX;
    PY(new double[][] { new double[] { 0, 0 }, new double[] { 0, -sf }, new double[] { bx, -wd }, new double[] { far, -wd }, new double[] { far, 0 } }, far, 0, false, "housing");
    PZ(Rect(far, far, a.webInX - p("edgeW"), a.webInY - p("edgeL")), p("gap"), a.zf, false, "diffuser");
    PY(new double[][] {
      new double[] { a.tipX, a.zRearOut }, new double[] { a.webOutX, a.zRearOut }, new double[] { a.webOutX, a.zFront }, new double[] { a.tipX, a.zFront },
      new double[] { a.tipX, a.zf }, new double[] { a.webInX, a.zf }, new double[] { a.webInX, a.zRearIn }, new double[] { a.tipX, a.zRearIn } },
      far, a.ys, false, "side channel");
    PX(new double[][] {
      new double[] { a.tipY, a.zRearOut }, new double[] { a.webOutY, a.zRearOut }, new double[] { a.webOutY, a.zFront }, new double[] { a.tipY, a.zFront },
      new double[] { a.tipY, a.zf }, new double[] { a.webInY, a.zf }, new double[] { a.webInY, a.zRearIn }, new double[] { a.tipY, a.zRearIn } },
      far, a.xe, false, "end channel");
    Finish(path, "lb_mock_corner", 0.75, 0.75, 0.75, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- spacer: fills the slot behind the diffuser, mid-span
  // Same section as the tongues of the corner blocks. Epoxied to the channel (rear leg and web), NOT to the sheet:
  // a push on the front of the diffuser goes straight into the rear leg in compression, and no bond is asked to hold it.
  // Own frame: x along the channel, y into the slot from the web (y = 0), z through the thickness. Prints flat.
  static void BuildSpacer(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double th = a.zSeat - a.zb, d = p("chanSlotDepth") - p("spacerShort"), c = p("spacerCham"), len = p("spacerLen");
    PX(new double[][] { new double[] { 0, c }, new double[] { c, 0 }, new double[] { d, 0 }, new double[] { d, th }, new double[] { c, th }, new double[] { 0, th - c } }, 0, len, false, "spacer");
    double sideFree = p("diffL") + 2 * p("edgeL") + 2 * p("chanFloor") - 2 * p("armSide") - 2 * p("tongueLen"), endFree = p("diffW") + 2 * p("edgeW") + 2 * p("chanFloor") - 2 * p("armEnd") - 2 * p("tongueLen");
    int ns = (int)p("spacerPerSide"), ne = (int)p("spacerPerEnd");
    log.AppendLine(String.Format("  spacer: {0:F2} thick (same as the tongues), {1:F1} into a {2:F2} slot, {3:F0} long, {4:F1} chamfer on the web-side edges", th, d, p("chanSlotDepth"), len, c));
    log.AppendLine(String.Format("  side channel: {0:F0} between tongues, {1} spacers -> {2:F0} of unsupported sheet edge between supports", sideFree, ns, (sideFree - ns * len) / (ns + 1)));
    log.AppendLine(String.Format("  end channel: {0:F0} between tongues, {1} spacers -> {2:F0} between supports; {3} spacers in all", endFree, ne, (endFree - ne * len) / (ne + 1), 2 * ns + 2 * ne));
    Finish(path, "lb_spacer", 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- fit gauge
  // A stepped bar to try in the channel slot, and four notches to try on the diffuser edge.
  // Steps get narrower away from the handle. Notches: the pair on the +y edge (the edge with the
  // small mark hole) are slot0 and slot0+d, mark end first; the pair on the -y edge continue.
  static void BuildGauge(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    double h = p("gaugeH"), sl = p("gaugeStepLen"), w0 = p("gaugeStepW0"), dw = p("gaugeStepDW"), hl = p("gaugeHandleLen"), hw = p("gaugeHandleW");
    int n = (int)p("gaugeSteps");
    List<double[]> up = new List<double[]>(), dn = new List<double[]>();
    up.Add(new double[] { -hl, hw / 2 }); up.Add(new double[] { 0, hw / 2 });
    dn.Add(new double[] { -hl, -hw / 2 }); dn.Add(new double[] { 0, -hw / 2 });
    for (int i = 0; i < n; i++) {
      double w = w0 - i * dw;
      up.Add(new double[] { i * sl, w / 2 }); up.Add(new double[] { (i + 1) * sl, w / 2 });
      dn.Add(new double[] { i * sl, -w / 2 }); dn.Add(new double[] { (i + 1) * sl, -w / 2 });
      log.AppendLine(String.Format("  step {0}: x {1:F0}..{2:F0}  width {3:F2}", i + 1, i * sl, (i + 1) * sl, w));
    }
    dn.Reverse(); up.AddRange(dn);
    Prism(up.ToArray(), 0, h, false, "gauge body");
    double s0 = p("gaugeSlot0"), sd = p("gaugeSlotD"), dep = p("gaugeSlotDepth");
    double[] xs = { -hl * 0.72, -hl * 0.28 };
    for (int k = 0; k < 4; k++) {
      double sw_ = s0 + k * sd, xc = xs[k % 2]; int side = k < 2 ? 1 : -1;
      double ya = side * (hw / 2 - dep), yb = side * (hw / 2 + 1);
      Prism(Rect(xc - sw_ / 2, Math.Min(ya, yb), xc + sw_ / 2, Math.Max(ya, yb)), -1, h + 1, true, "notch " + sw_.ToString("F1"));
      log.AppendLine(String.Format("  notch {0:F1}: x {1:F1}, {2} edge", sw_, xc, side > 0 ? "+y (marked)" : "-y"));
    }
    if (hw - 2 * dep < 6) log.AppendLine("  !! handle web between notches is under 6 mm");
    Cyls(new double[][] { new double[] { -hl + 3.0, hw / 2 - 3.0, 2.0 } }, -1, h + 1, true, "mark hole");
    Finish(path, "lb_fit_gauge", 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  static void ExportPrint(string dir, string tag, string[] parts) {
    int e = 0, w = 0;
    int oldQ = sw.GetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality);
    bool oldT = sw.GetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive);
    sw.SetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality, (int)swSTLQuality_e.swSTLQuality_Fine);
    sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, true);
    foreach (string n in parts) {
      ModelDoc2 d = (ModelDoc2)sw.OpenDoc6(dir + "\\lb_" + n + ".SLDPRT", (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
      if (d == null) { log.AppendLine("!! could not open " + n); continue; }
      d = (ModelDoc2)sw.ActivateDoc3(d.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref e);
      string stl = dir + "\\stl\\lb_" + n + "_" + tag + ".STL";
      bool ok = d.Extension.SaveAs(stl, 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      log.AppendLine(n + ": STL " + ok + "  " + stl);
    }
    sw.SetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality, oldQ);
    sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, oldT);
  }

  public static string Run(string dir, string what, string imgDir, string stlTag, string stlParts, string[] keys, double[] vals) {
    P = new Dictionary<string, double>(); PKeys = new List<string>(keys);
    for (int i = 0; i < keys.Length; i++) P[keys[i]] = vals[i];
    try { sw = (SldWorks)Marshal.GetActiveObject("SldWorks.Application"); }
    catch (Exception) { return "SolidWorks is not running. Start it and run again."; }
    try {
      if (what == "gauge") BuildGauge(dir + SEP + "lb_fit_gauge.SLDPRT", imgDir);
      if (what == "blockA") { sgn = 1; BuildBlock(dir + SEP + "lb_corner_block_A.SLDPRT", imgDir, "lb_corner_block_A"); }
      if (what == "blockB") { sgn = -1; BuildBlock(dir + SEP + "lb_corner_block_B.SLDPRT", imgDir, "lb_corner_block_B"); }
      if (what == "bracketA") { sgn = 1; BuildBracket(dir + SEP + "lb_bracket_A.SLDPRT", imgDir, "lb_bracket_A"); }
      if (what == "bracketB") { sgn = -1; BuildBracket(dir + SEP + "lb_bracket_B.SLDPRT", imgDir, "lb_bracket_B"); }
      if (what == "footA") { sgn = 1; footMode = true; BuildBracket(dir + SEP + "lb_foot_A.SLDPRT", imgDir, "lb_foot_A"); }
      if (what == "footB") { sgn = -1; footMode = true; BuildBracket(dir + SEP + "lb_foot_B.SLDPRT", imgDir, "lb_foot_B"); }
      if (what == "spacer") BuildSpacer(dir + SEP + "lb_spacer.SLDPRT", imgDir);
      if (what == "mock") BuildMock(dir + SEP + "lb_mock_corner.SLDPRT", imgDir);
      if (what == "stl") ExportPrint(dir, stlTag, stlParts.Split(','));
    } catch (Exception ex) { log.AppendLine("!! stopped: " + ex.Message + "\n" + ex.StackTrace); }
    return log.ToString();
  }
}
'@

$params = Get-Content (Join-Path $here "lightbox_params.json") -Raw | ConvertFrom-Json
$keys = @(); $vals = @()
foreach ($prop in $params.PSObject.Properties) { $keys += $prop.Name; $vals += [double]$prop.Value }
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs
foreach ($r in $refs) { [Reflection.Assembly]::LoadFrom($r) | Out-Null }
[Gen]::Run($outDir, $What, $ImgDir, $StlTag, $StlParts, [string[]]$keys, [double[]]$vals)
