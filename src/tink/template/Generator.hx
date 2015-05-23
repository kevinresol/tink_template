package tink.template;

import haxe.macro.Expr;
import tink.syntaxhub.FrontendContext;

using haxe.macro.Context;
using tink.MacroApi;

class Generator {
	
	static function getPos(t:TplExpr)
		return
			if (t == null) null;
			else switch t {
				case Const(_, pos): pos;
				case Define(_, e), Meta(_, e): getPos(e);
				case Switch(e, _), While(e, _), For(e, _), If(e, _, _), Yield(e), Do(e): e.pos;
				case Var([]): Context.currentPos();
				case Block([]): Context.currentPos();
				case Var(a): a[0].expr.pos;
				case Function(_, _, t): getPos(t);
				case Block(a): getPos(a[0]);
			}	
	
	static function posComment(pos:Position) {
		var pos = Context.getPosInfos(pos);
		return '<!-- POSITION: ${haxe.Json.stringify(pos)} -->';
	}
	
	static function generateExpr(t:TplExpr):Expr {
		var pos = getPos(t);		
		var ret:Expr = 
			if (t == null) null;
			else switch t {
				case Meta(meta, e):
					var e = generateExpr(e);
					for (m in meta)
						e = EMeta(m, e).at(m.pos);
					e;
				case While(cond, body):
					macro @:pos(pos) 
						while ($cond) ${generateExpr(body)};
				case Const(value, pos):
					macro @:pos(pos) ret.add(new tink.template.Html($v{value}));
				case Define(name, value):
					macro @:pos(pos) var $name = ${functionBody(value)};
				case Yield(e):
					macro @:pos(e.pos) ret.add($e);
				case Do(e):
					e;
				case Var(vars):
					EVars(vars).at(pos);
				case Switch(target, cases):
					ESwitch(target, [for (c in cases) {
						guard: c.guard,
						values: c.values,
						expr: generateExpr(c.expr),
					}], null).at(pos);
				case If(cond, cons, alt):
					macro @:pos(pos)
						if ($cond)
							${generateExpr(cons)}
						else
							${generateExpr(alt)};
				case For(target, body, legacy):
					var pre = macro {};
					
					if (legacy) {
						
						target = macro @:pos(target.pos) __current__ in $target;
						
						pos.warning('foreach loops are discouraged');
						
						pre = (macro __current__).bounceExpr(
							function (e:Expr) {
								var tmp = MacroApi.tempName();
								var v = EVars(
									[for (f in e.typeof().sure().getFields().sure()) 
										if (f.isPublic && f.kind.getName() == 'FVar') {
											var name = f.name;
											{
												name: f.name,
												type: null,
												expr: macro @:pos(e.pos) $i{tmp}.$name
											}
										}
									]							
								).at(e.pos);
								return macro @:pos(e.pos) @:mergeBlock {
									var $tmp = $e;
									$v;
								}
							}
						);
						
					}
					
					macro @:pos(pos)
						for ($target) {
							$pre;
							${generateExpr(body)};
						}
							
				case Function(name, args, body):						
					functionBody(body, true).func(args, false).asExpr(name);
				case Block(exprs):
					exprs.map(generateExpr).toBlock(pos);
			}
		
		return ret;
	}		
	
	static function functionBody(body:TplExpr, ?withReturn:Bool):Expr {
		var pos = getPos(body);
		var body = [body];
		if (Context.defined('debug'))
			body.unshift(Const(posComment(pos), pos));
		
		var ret = macro @:pos(pos) ret.collapse();
		if (withReturn)
			ret = macro return $ret;
		
		return macro @:pos(pos) {
			var ret = tink.template.Html.buffer();
			$a{body.map(generateExpr)};
			$ret;
		}
	}
	
	static public function generate(decl:Array<TplExpr.TplDecl>, into:FrontendContext) {
		
		var className = into.name;
		var type = into.getType(into.name);
		
		switch type.kind {
			case TDClass(_, _, false), TDAbstract(_, _, _):
			default: 
				type.pos.error('Type must be abstract or class to be augmented with template in ${type.pos.getPosInfos().file}');
		}
		
		for (decl in decl)
			switch decl {
				case SuperType(t, true, pos):
					type.kind =
						switch type.kind {
							case TDClass(null, i, _): TDClass(t, i, false);
							case TDClass(s, _, _): pos.error('cannot have multiple super classes');
							default: pos.error('type cannot have super class');
						}
						
				case SuperType(t, false, pos):
					type.kind =
						switch type.kind {
							case TDClass(s, null, _): TDClass(s, [t], false);
							case TDClass(s, i, _): TDClass(s, i.concat([t]), false);
							default: pos.error('type cannot implement interfaces');
						}

				case Meta(m):
					type.meta =
						if (type.meta == null) m;
						else type.meta.concat(m);
				case VanillaField(f):
					type.fields.push(f);
					
				case Using(path, pos):
					into.addUsing(path, pos);
					
				case Import(path, mode, pos):
					into.addImport(path, mode, pos);
					
				case TemplateField(f, tpl):
					type.fields.push(f);
					switch f.kind {
						case FFun(f):
							f.expr = functionBody(tpl, true);
						case FVar(t, _):
							f.kind = FVar(t, functionBody(tpl));
						case FProp(get, set, t, _):
							f.kind = FProp(get, set, t, functionBody(tpl));
					}				
			}
			
		for (f in type.fields)
			f.publish();
		
	}
}